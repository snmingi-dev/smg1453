#!/usr/bin/env python
"""team_agent.py

Codex CLI만 사용해서 서브에이전트 오케스트레이션을 수행하는 스크립트.
OpenAI API 키 없이 Codex 로그인 세션으로 동작한다.

실행 예시:
- python team_agent.py "지도 앱 렉 줄이고 테스트까지 진행해줘"
- python team_agent.py --workspace "C:/Users/zoot1/OneDrive/문서/fantasy-map-editor"
  -> 이후 프롬프트 입력
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


MAX_CONTEXT_CHARS = 12000


def npx_bin() -> str:
    return "npx.cmd" if os.name == "nt" else "npx"


ROLE_INSTRUCTIONS: dict[str, str] = {
    "Planner": (
        "당신은 메인 팀장(Planner)입니다. 요청을 분석하고 작업 순서를 통제합니다.\n"
        "- 복합 작업이면 반드시 순서를 정해 단계별로 handoff 지시를 만드세요.\n"
        "- 각 단계 입력과 완료 기준을 짧고 명확하게 작성하세요.\n"
        "- 최종 단계에서는 전체 결과를 통합 보고하고 남은 리스크/다음 액션을 정리하세요.\n"
        "- 한국어로 작성하세요."
    ),
    "Implementer": (
        "당신은 구현 담당(Implementer)입니다.\n"
        "- 실제 파일 생성/수정/명령 실행으로 기능을 구현하세요.\n"
        "- 완료 후 변경 파일, 핵심 변경점, 검증 결과를 보고하세요.\n"
        "- 미완료/리스크가 있으면 이유와 해결 방향을 남기세요.\n"
        "- 한국어로 작성하세요."
    ),
    "Reviewer": (
        "당신은 코드 리뷰 담당(Reviewer)입니다.\n"
        "- 버그/회귀/보안/성능 리스크를 심각도 순으로 찾으세요.\n"
        "- 근거 파일 경로를 명시하고 수정 필요 항목을 구분하세요.\n"
        "- 리뷰 결과를 다음 담당자가 바로 처리할 수 있게 작성하세요.\n"
        "- 한국어로 작성하세요."
    ),
    "Debugger": (
        "당신은 디버깅 담당(Debugger)입니다.\n"
        "- 에러 원인을 재현/분석하고 코드 수정으로 해결하세요.\n"
        "- 수정 후 재현 테스트를 다시 수행하세요.\n"
        "- 필요하면 Tester가 검증하기 좋은 체크리스트를 남기세요.\n"
        "- 한국어로 작성하세요."
    ),
    "Tester": (
        "당신은 테스트 담당(Tester)입니다.\n"
        "- 테스트를 작성/실행하고 결과를 수치와 함께 보고하세요.\n"
        "- 실패 시 실패 원인과 재현 방법을 명확히 남기세요.\n"
        "- 검증 공백(아직 테스트 못한 부분)을 반드시 기록하세요.\n"
        "- 한국어로 작성하세요."
    ),
}


@dataclass
class WorkflowDecision:
    is_complex: bool
    order: list[str]
    reason: str


@dataclass
class StepResult:
    role: str
    content: str


class CodexExecError(RuntimeError):
    pass


def detect_workflow(task: str) -> WorkflowDecision:
    text = task.strip()
    lowered = text.lower()

    is_complex = (
        len(text) >= 80
        or text.count("\n") >= 2
        or sum(text.count(t) for t in ["그리고", "또", "및", "먼저", "다음", "마지막"]) >= 2
    )

    debug_keywords = ["버그", "오류", "에러", "traceback", "예외", "크래시", "안됨", "실패", "디버그"]
    review_keywords = ["리뷰", "검토", "품질", "보안", "성능 점검"]
    test_keywords = ["테스트", "검증", "pytest", "회귀", "유닛테스트"]

    has_debug = any(k in text for k in debug_keywords) or any(k in lowered for k in debug_keywords)
    has_review = any(k in text for k in review_keywords)
    has_test = any(k in text for k in test_keywords)

    if has_debug:
        return WorkflowDecision(True, ["Planner", "Debugger", "Tester", "Planner"], "디버그 성격 요청")
    if is_complex:
        return WorkflowDecision(True, ["Planner", "Implementer", "Reviewer", "Tester", "Planner"], "복합 작업")
    if has_review and not has_test:
        return WorkflowDecision(False, ["Planner", "Reviewer", "Planner"], "리뷰 중심 단일 작업")
    if has_test and not has_review:
        return WorkflowDecision(False, ["Planner", "Implementer", "Tester", "Planner"], "테스트 중심 단일 작업")
    return WorkflowDecision(False, ["Planner", "Implementer", "Planner"], "일반 단일 작업")


def trim_context(text: str, limit: int = MAX_CONTEXT_CHARS) -> str:
    if len(text) <= limit:
        return text
    head = text[: int(limit * 0.65)]
    tail = text[-int(limit * 0.35) :]
    return head + "\n\n...(중략)...\n\n" + tail


async def check_codex_cli() -> None:
    proc = await asyncio.create_subprocess_exec(
        npx_bin(),
        "-y",
        "codex",
        "--version",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    out, err = await proc.communicate()
    if proc.returncode != 0:
        raise CodexExecError(
            "Codex CLI를 실행할 수 없습니다. npx/codex 설치 상태를 확인하세요.\n"
            f"stderr: {err.decode('utf-8', errors='replace')}"
        )
    _ = out


async def run_codex_exec(
    prompt: str,
    workspace: Path,
    model: str,
    dangerous_bypass: bool,
    max_retries: int = 3,
) -> str:
    last_error = ""
    full_auto = True
    model_to_use = model

    for attempt in range(1, max_retries + 1):
        with tempfile.NamedTemporaryFile(delete=False, suffix=".txt") as tmp:
            output_path = Path(tmp.name)

        try:
            cmd = [
                npx_bin(),
                "-y",
                "codex",
                "exec",
            ]
            if dangerous_bypass:
                cmd.append("--dangerously-bypass-approvals-and-sandbox")
            elif full_auto:
                cmd.append("--full-auto")
            cmd.extend(
                [
                    "--model",
                    model_to_use,
                    "--cd",
                    str(workspace),
                    "--skip-git-repo-check",
                    "--output-last-message",
                    str(output_path),
                    "-",
                ]
            )

            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await proc.communicate(prompt.encode("utf-8"))

            std_out = stdout.decode("utf-8", errors="replace").strip()
            std_err = stderr.decode("utf-8", errors="replace").strip()

            if proc.returncode == 0:
                if output_path.exists():
                    message = output_path.read_text(encoding="utf-8", errors="replace").strip()
                    if message:
                        return message
                if std_out:
                    return std_out
                return "(응답이 비어 있습니다.)"

            if "unexpected argument '--full-auto'" in std_err and full_auto:
                full_auto = False
                last_error = std_err
                continue

            if ("does not exist or you do not have access" in std_err.lower() or "not supported" in std_err.lower()) and model_to_use != "gpt-5":
                model_to_use = "gpt-5"
                last_error = std_err
                continue

            if "Not logged in" in std_err or "login" in std_err.lower():
                raise CodexExecError(
                    "Codex 인증이 필요합니다. 먼저 `npx -y codex login`을 실행하세요.\n"
                    f"원문 오류: {std_err}"
                )

            last_error = f"exit={proc.returncode}\nstdout:\n{std_out}\n\nstderr:\n{std_err}"
            if attempt < max_retries:
                await asyncio.sleep(float(attempt))
        finally:
            try:
                output_path.unlink(missing_ok=True)
            except Exception:
                pass

    raise CodexExecError(f"codex exec 실행 실패 (재시도 {max_retries}회).\n{last_error}")


def build_prompt(
    role: str,
    user_task: str,
    decision: WorkflowDecision,
    step_index: int,
    total_steps: int,
    prior_results: list[StepResult],
) -> str:
    history_lines = []
    for idx, r in enumerate(prior_results, start=1):
        history_lines.append(f"[{idx}] {r.role} 결과\n{trim_context(r.content, 2500)}")
    history = "\n\n".join(history_lines) if history_lines else "(이전 단계 없음)"

    order_text = " -> ".join(decision.order)

    base = (
        f"[역할]\n{role}\n\n"
        f"[역할 지침]\n{ROLE_INSTRUCTIONS[role]}\n\n"
        f"[사용자 원문 요청]\n{user_task}\n\n"
        f"[오케스트레이션 규칙]\n"
        f"- 판정: {'복합' if decision.is_complex else '단순'} ({decision.reason})\n"
        f"- 고정 순서: {order_text}\n"
        f"- 현재 단계: {step_index}/{total_steps}\n"
        f"- 단계 완료 후 다음 담당자가 이해할 수 있게 산출물/근거를 남길 것\n\n"
        f"[이전 단계 산출물]\n{history}\n"
    )

    if role == "Planner" and step_index == 1:
        return (
            base
            + "\n[작업]\n"
            + "요청을 작업 단위로 분해하고, 바로 다음 담당자가 실행할 수 있는 handoff 지시를 작성하세요.\n"
            + "출력 형식:\n"
            + "1) 작업 분해\n2) 우선순위\n3) 다음 담당자 handoff 메모\n"
        )

    if role == "Planner" and step_index == total_steps:
        return (
            base
            + "\n[작업]\n"
            + "전체 결과를 최종 보고서로 통합하세요.\n"
            + "출력 형식:\n"
            + "1) 수행 내역 요약\n2) 검증/테스트 결과\n3) 남은 이슈 및 권장 다음 단계\n"
        )

    return (
        base
        + "\n[작업]\n"
        + "현재 역할 지침에 따라 실제 작업을 수행하고, 결과를 간결하게 보고하세요.\n"
        + "출력 형식:\n"
        + "1) 실행한 일\n2) 변경/근거\n3) 다음 handoff 메모\n"
    )


async def run_task(
    task: str,
    workspace: Path,
    max_retries: int,
    model: str,
    dangerous_bypass: bool,
) -> str:
    decision = detect_workflow(task)
    prior: list[StepResult] = []

    total = len(decision.order)
    for idx, role in enumerate(decision.order, start=1):
        prompt = build_prompt(
            role=role,
            user_task=task,
            decision=decision,
            step_index=idx,
            total_steps=total,
            prior_results=prior,
        )
        result_text = await run_codex_exec(
            prompt=prompt,
            workspace=workspace,
            model=model,
            dangerous_bypass=dangerous_bypass,
            max_retries=max_retries,
        )
        prior.append(StepResult(role=role, content=result_text))

    return prior[-1].content if prior else "(실행 결과 없음)"


async def async_main() -> int:
    parser = argparse.ArgumentParser(description="Codex CLI 서브에이전트 오케스트레이터")
    parser.add_argument("task", nargs="*", help="실행할 사용자 작업 지시")
    parser.add_argument(
        "--workspace",
        default=os.getcwd(),
        help="작업 루트 디렉터리 (기본값: 현재 디렉터리)",
    )
    parser.add_argument(
        "--max-retries",
        type=int,
        default=3,
        help="codex exec 실패 시 재시도 횟수 (기본값: 3)",
    )
    parser.add_argument(
        "--model",
        default=os.getenv("CODEX_MODEL", "gpt-5"),
        help="Codex 실행 모델 (기본값: gpt-5 또는 CODEX_MODEL 환경변수)",
    )
    parser.add_argument(
        "--safe",
        action="store_true",
        help="안전 모드(--full-auto). 기본은 전권 모드(--dangerously-bypass-approvals-and-sandbox).",
    )
    args = parser.parse_args()

    workspace = Path(args.workspace).resolve()
    if not workspace.exists() or not workspace.is_dir():
        raise CodexExecError(f"유효하지 않은 workspace 경로: {workspace}")

    dangerous_bypass = not args.safe
    if dangerous_bypass:
        print("[WARN] 전권 모드로 실행합니다: --dangerously-bypass-approvals-and-sandbox")
    else:
        print("[INFO] 안전 모드로 실행합니다: --full-auto")

    await check_codex_cli()

    if args.task:
        task = " ".join(args.task).strip()
        final_report = await run_task(
            task=task,
            workspace=workspace,
            max_retries=args.max_retries,
            model=args.model,
            dangerous_bypass=dangerous_bypass,
        )
        print("\n=== Planner 최종 보고 ===")
        print(final_report)
        return 0

    print("작업 지시를 입력하세요. 종료하려면 exit 또는 quit 입력")
    while True:
        try:
            task = input("\n지시> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n종료합니다.")
            return 0

        if task.lower() in {"exit", "quit"}:
            return 0
        if not task:
            continue

        final_report = await run_task(
            task=task,
            workspace=workspace,
            max_retries=args.max_retries,
            model=args.model,
            dangerous_bypass=dangerous_bypass,
        )
        print("\n=== Planner 최종 보고 ===")
        print(final_report)


def main() -> None:
    try:
        code = asyncio.run(async_main())
    except CodexExecError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        raise SystemExit(1)
    except Exception as exc:
        print(f"[ERROR] 예기치 못한 오류: {exc}", file=sys.stderr)
        raise SystemExit(1)
    raise SystemExit(code)


if __name__ == "__main__":
    main()
