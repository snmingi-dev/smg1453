# Fantasy Map Team Orchestration

## 1) 목적

이 문서는 `fantasy-map-editor`를 "판타지 지도 제작팀" 형태로 운영하기 위한 역할 분배 기준과,
현재 코드 기준의 완료 작업 현황을 함께 기록한다.

핵심 원칙:

- 역할은 기능 단위가 아니라 모듈 경계 단위로 나눈다.
- handoff는 항상 "변경 근거 + 검증 결과 + 다음 담당 액션" 3종을 포함한다.
- 완료 여부는 추정이 아니라 코드 근거로 판정한다.

## 2) 팀 구조 및 오너십

### Lead (총괄/통합 게이트)

- 오너 파일: `scripts/main.gd`
- 책임:
  - 전체 입력 라우팅, UI 상태, 툴 전환, 편집 흐름 통합.
  - 스냅샷 캡처/복원, Undo/Redo 트리거, 저장/불러오기/내보내기 진입점 관리.
  - 배포 직전 통합 품질 게이트(지형/정치/IO/성능).

### Terrain Team (지형 제작)

- 오너 파일: `scripts/systems/terrain_layer.gd`, `scripts/models/terrain_tool_config.gd`
- 책임:
  - 육지 페인트/지우기, 해안 처리, 산/강 스트로크 로직.
  - 브러시 타입(`circle/texture/noise`) 품질과 성능 균형.
  - 타일 단위 삭제와 land mask chunk 직렬화.

### Political Team (국가/경계 제작)

- 오너 파일: `scripts/systems/political_layer.gd`
- 책임:
  - 국가 칠하기, 선택, 색상/이름 변경, 라벨 앵커, 벡터 경계 계산.
  - 국가 생성 arm/disarm 흐름, 확정 UX와 일관성 유지.

### Persistence Team (저장/복구 파이프라인)

- 오너 파일: `scripts/systems/project_io.gd`, `scripts/systems/async_project_saver.gd`
- 책임:
  - 저장 스키마 진화, 하위 호환 로드, 비동기 저장 안정성.
  - autosave 시점 정책과 저장 실패 복구 시나리오 관리.

### QA Core (회귀/복원력)

- 오너 파일: `scripts/systems/command_stack.gd` + `scripts/main.gd`(snapshot 복원 경로)
- 책임:
  - Undo/Redo 신뢰성, 스냅샷 정합성, E2E 회귀 검증.
  - "편집 -> 저장 -> 로드 -> Undo/Redo" 경로를 릴리즈 게이트로 유지.

## 3) 운영 오케스트레이션 프로토콜

표준 흐름:

1. Planner(Lead) - 요구 분해, 수용 기준 정의.
2. Implementer(각 팀) - 기능 구현/수정.
3. Reviewer(교차 팀) - 회귀/성능/UX 리스크 점검.
4. Tester(QA Core) - E2E 및 저장 복구 시나리오 검증.
5. Lead - 통합 승인/보류 결정.

handoff 템플릿:

- 실행한 일
- 근거 파일 및 핵심 라인
- 검증 결과(성공/실패 + 재현 방법)
- 다음 담당자 액션

## 4) 현재까지 완료 작업 분석 (코드 근거)

아래 항목은 코드에서 확인된 상태 기준이다.

### A. 완료(Implemented)

1) 지형 편집 기본기

- 육지 페인트/지우기 스트로크 동작: `scripts/systems/terrain_layer.gd:213`
- 산/강 스트로크: `scripts/systems/terrain_layer.gd:262`, `scripts/systems/terrain_layer.gd:276`
- 브러시 타입 지원(`circle/texture/noise`): `scripts/models/terrain_tool_config.gd:4`, `scripts/systems/terrain_layer.gd:218`
- 타일 삭제: `scripts/systems/terrain_layer.gd:289`

2) 국가 편집 핵심 흐름

- 국가 칠하기 시작/생성 arm 로직: `scripts/systems/political_layer.gd:154`
- 국가 칠하기 세그먼트 적용: `scripts/systems/political_layer.gd:215`
- 국가 선택, 이름/색상 변경: `scripts/systems/political_layer.gd:308`, `scripts/systems/political_layer.gd:343`, `scripts/systems/political_layer.gd:356`
- 확정 대기 UI(Enter/Esc/타임아웃) 제어: `scripts/main.gd:539`, `scripts/main.gd:550`, `scripts/main.gd:568`, `scripts/main.gd:582`

3) 실행 취소/다시 실행

- 커맨드 스택 구현: `scripts/systems/command_stack.gd:15`, `scripts/systems/command_stack.gd:30`, `scripts/systems/command_stack.gd:38`
- 메인 레벨 Undo/Redo + 스냅샷 복원: `scripts/main.gd:701`, `scripts/main.gd:714`, `scripts/main.gd:727`, `scripts/main.gd:742`

4) 저장/불러오기/내보내기

- 프로젝트 payload 및 저장/로드: `scripts/systems/project_io.gd:5`, `scripts/systems/project_io.gd:43`, `scripts/systems/project_io.gd:70`
- 비동기 저장 워커: `scripts/systems/async_project_saver.gd:87`
- autosave + recent + PNG export: `scripts/main.gd:1615`, `scripts/main.gd:1637`, `scripts/main.gd:1668`

5) 문서화된 핵심 범위 반영

- 구현 코어 항목 정리: `README.md:5`
- 구현 계획 매핑 문서: `docs/IMPLEMENTED_PLAN.md:1`

### B. 부분 완료 / 제약 존재

1) 지역(Region) 분할 기능

- `create_region_from_stroke`는 실제 생성 로직으로 전환됨.
- 현재 정책은 "선택 국가 내부 클램프 + 과도 중첩 제한"(MVP)이며, 다중 조각 교차 시 최대 면적 1개만 채택.

판정: "핵심 동작은 구현 완료, 세부 정책(다중 조각 병합/편집 UX)은 후속 고도화 대상".

### C. 현재 리스크

- 다중 섬/복잡 경계 국가에서 교차 조각이 여러 개 생길 때 최대 면적 1개만 채택되어 일부 기대와 다를 수 있음.
- 스냅샷 기반 Undo/Redo는 안정적이지만, 대형 맵에서 메모리 압력이 늘어날 수 있어 QA 프로파일링이 필요함.
- 비동기 저장 실패 시 재시도/알림 정책은 최소 수준이므로 운영 UX를 더 명확히 할 여지가 있음.

## 5) 다음 스프린트 권장 분배

1. Political Team

- 다중 교차 조각 병합 정책(필요 시 복수 region 자동 생성)을 설계해 Region 편집 완성도 향상.

2. QA Core

- 대형 맵(예: 4K 캔버스)에서 Undo/Redo 메모리/지연 측정 시나리오 추가.

3. Persistence Team

- 저장 실패 코드별 사용자 메시지 가이드 및 재시도 정책 강화.

4. Lead

- 릴리즈 게이트에 "Region 동작 상태(온/오프)"를 명시해 스펙-구현 불일치 방지.

## 6) 실행 커맨드 예시

`team_agent.py` 기반 오케스트레이션 실행:

```bash
python "C:\Users\zoot1\OneDrive\문서\fantasy-map-editor\team_agent.py" --workspace "C:\Users\zoot1\OneDrive\문서\fantasy-map-editor" "위 오너십 기준으로 이번 스프린트 업무를 분배하고, Region 기능 상태를 포함해 실행 계획을 작성해줘"
```
