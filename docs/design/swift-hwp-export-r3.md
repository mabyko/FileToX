# HWP 내보내기 r3 구현·비교 보고서

공개 문서 20개에 대해 선택한 C(rhwp → HWPX → Filee 문서 모델·writer)에
Unhwp 수식 변환기의 Swift 포트를 더했다. A(Unhwp)·B(rhwp 직접 내보내기)는
r2 결과를 유지하고 C만 새 helper로 60건 다시 실행했다.

## 구현

- Unhwp `405b17e137b3ca06299dcbc8a156599ac7027e91`의 `src/equation.rs`를
  Swift로 포팅했다. MIT 저작권·허가문은 Swift 헤더와 `docs/upstream/Unhwp.*`에 있다.
- 수식은 HEquation으로 구분해 MD `$…$`/`$$…$$`, TXT LaTeX,
  HTML Pandoc의 `math inline` span으로 출력한다.
- 원본의 `SQRT n OF x` 버그, ROOT 뒤 비-OF 단어 소실, LaTeX 명령·변수 결합,
  LEFT/RIGHT 중괄호 구분자를 수정했다. 알 수 없는 키워드는 원본처럼 통과한다.
- 그림·표 캡션, Outline/개요/제목 스타일, 중간 머리말, 표·글상자 안의 머리말 정의,
  중첩 표·셀 줄바꿈을 보존한다.
- 부모 요청으로 main `42b1d80`을 병합했다. 문서 전용 이미지 helper를 제거하고
  EbookFiles.commonImage/dataUri/markdownImages를 전자책과 HWP가 함께 쓴다.
  sidecar 폴더는 mkdir, 파일은 writeFile/open으로 만들어 NFC 바이트를 유지한다.
  raw readdir UTF-8 바이트를 검사하는 회귀 테스트를 추가했다.

## r2 대비 결과

| 지표 | r2 C | r3 C |
|---|---:|---:|
| 변환 성공 TXT/MD/HTML | 20/19/19 | 20/20/20 |
| 한글이 들어간 잘못된 pre (Markdig) | 498 | 0 |
| MD 제목 | 0 | 140 |
| 머리말 보존 TXT | 10/15 | 15/15 |
| 표 셀 텍스트 보존 TXT | 6,224/6,379 | 6,360/6,379 |
| 표 셀 텍스트 보존 MD | 4,193/4,349 | 6,359/6,379 |
| 표 셀 텍스트 보존 HTML | 4,343/4,349 | 6,374/6,379 |
| MD bytes (본문) | 78,590,732 | 1,001,283 |
| HTML bytes | 85,302,543 | 18,410,632 |

MD sidecar 포함 합계는 12,377,756 bytes다. r2의
MD/HTML 한 문서는 실패했으므로 셀 보존 분모도 서로 다르다. r2와 같은 6-gram
일치도·문자 수·구조 수·소요 시간·파일 크기를 summary-r3.json에 유지했다.
TXT는 한글 200,454 → 202,736자다.

원본 HWPX 수식 525개에서 LaTeX 525개를 출력했고,
MD·TXT 모두 같은 LaTeX 525개를 확인했다. 빈 script 미지원
0개다. eqalign이 그대로 남은 수식 2개는 생성
집계에 포함된다. 생성 수가 완전한 수식 조판 성공 수를 뜻하지는 않는다.
기존 latexMath 정규식은 본문의 달러 기호도 세므로 수식 전용 집계를 별도로 추가했다.

treatise의 Fig. 1~6, Table 1은 TXT/MD/HTML에 모두 있다. exam_math의 머리말
11개 정의(그중 2개는 표 안에 있음)를 모두 읽고 출력한다. Pandoc commonmark_x에서도
한글 pre는 0개다.

## Filee reader/writer 대비 동작 변경 전체

1. **수식**: HWPX script를 HEquation(HText 하위 타입)으로 보존. MD $…$/$$…$$, TXT LaTeX, HTML Pandoc math inline span. 알 수 없는 단어는 Unhwp처럼 통과, 빈 script는 [unhwp:equation-unsupported], 비어 있지 않은 script의 빈 변환 결과는 MD 코드로 원문 보존.

2. **공통 머리말·꼬리말**: Filee 세 writer가 생략하던 머리말을 정의 위치에서, 꼬리말을 구역 끝에서 한 번씩 출력. HWPX는 같은 페이지 종류의 후속 머리말과 표·글상자 내부의 머리말 정의도 읽고 시작 본문 인덱스를 기록한다. 반복 인쇄·쪽 번호 재계산은 하지 않는다.

3. **Markdown 목록·공백**: 연속 목록에서 실제로 나타나는 깊이로 정규화해 시작 깊이가 0보다 커도 최상위는 들여쓰기 0칸. 선행 항목 없는 continuation은 일반 문단. 일반 문단의 앞 공백도 제거해 코드 블록 오인을 방지하며, codeShade의 명시적 코드 fence는 유지한다.

4. **중첩 표와 셀 줄바꿈**: TXT는 셀 블록을 재귀 순회하고 내부 줄·셀을 /·|로 구분. MD는 내부 행·문단·명시적 줄바꿈을 <br>, 내부 열을 /로 연결해 바깥 GFM 셀에 넣는다. MD 셀의 내부 문단 목록 번호는 기존처럼 생략한다.

5. **캡션**: 표 caption은 TXT/MD에서 표 앞에 출력(HTML caption은 유지). 그림·도형 caption subList는 HWPX reader가 인접 문단으로 보존하므로 이미지가 생략되어도 캡션은 남는다. 원래 그림 캡션의 위·아래 배치 속성은 재현하지 않는다.

6. **제목**: Heading n 외에 Outline n·개요 n·제목 n(1~9) 스타일도 읽고 MD # / HTML h1~h6으로 제한해 출력. 목록 속성이 함께 있는 heading도 HTML에서 목록보다 heading을 우선한다. 글자 크기만으로 제목을 추정하지 않는다.

7. **글상자**: TXT/MD의 글상자 안 중첩 표도 재귀적으로 보존. XHTML은 글상자의 표를 span 안의 텍스트·br로 풀어 HTML 문단 안에 블록 table을 삽입하지 않는다. 일반 본문/셀의 HTML 중첩 table은 유지한다.

8. **그림 경로**: UnhwpConverter가 공용 EbookFiles 이미지 helper를 사용한다. Filee Ebooks CommonImage/DataUri/MarkdownImages 규칙대로 PNG/JPEG/GIF/SVG 유지, BMP 등은 PNG, alpha 없는 WebP/AVIF/JXL/TIFF는 JPEG(90). 공용 commonImage의 읽기·정규화 실패는 생략하며 data URI 읽기·sidecar 쓰기 실패는 전파한다. MD는 output_files/imgNNNN.ext 상대 링크·중복 재사용, HTML은 data URI.

9. **다른 변환 호출부**: writer의 공개 함수 시그니처는 그대로. e-book·DOCX 등 HDocument를 쓰는 호출부에도 위 공통 writer 변경이 적용된다. HWPX/DOCX package writer는 HEquation을 기존 HText처럼 원래 script로 기록하므로 수식 객체/OMML 쓰기는 이 작업 범위에 없다. 부모 요청에 따라 main 42b1d80을 병합하고 문서 전용 이미지 helper를 제거했다. 전자책과 HWP 모두 EbookFiles.commonImage/dataUri/markdownImages를 공유한다. markdownImages를 내부 공용 API로 옮기고 부속 파일 쓰기는 writeFile(open)로 바꿔 한글 이름의 NFC를 보존한다.

## 검증과 남은 차이

- `swift build --product FileToXEngine`, `swift build --build-tests` 통과.
- `swift test --filter FileToXEngineTests`: 360개, 실패 0개,
  건너뜀 15개. 새 회귀 테스트 14개는 통과했다.
  원본 equation.rs의 20개 테스트에 있는 30개 정확 일치 assertion과 matrix assertion을 포함한다.
- 기존 md_render.py(Markdig)와 지정된 Pandoc commonmark_x로 20개 MD를 렌더링했다.
- report-r3.html은 한국어·자체 포함이며 로컬 절대 경로를 넣지 않았다.
  summary-r3.json, scripts-r3와 실행 로그를 비교 작업 디렉터리에 함께 보관한다.

- 셀 보존 점수가 100%가 아닌 경우에는 중첩 표의 구분 기호, 각주를 별도 주석으로 이동, 표 안 머리말을 구역 흐름으로 옮기는 차이가 있다. TXT/MD/HTML은 동일한 문자 연결 순서나 원래 페이지 배치를 보장하지 않는다.
- Unhwp 원본이 지원하지 않는 eqalign 등의 DSL은 그대로 통과한다. LaTeX 생성 수는 완전한 수식 렌더링 성공 수가 아니다. CASES의 복잡한 정렬, 임의 확장 키워드 등은 추가 문법 포팅이 필요하다.
- HTML은 요청한 Pandoc 식 LaTeX span을 포함한다. MathJax/KaTeX를 번들하거나 네트워크에서 로드하지 않으므로 브라우저만으로 수식 조판을 보장하지 않는다.
- ImageIO가 읽지 못하는 WMF 같은 그림은 생략한다. JPEG/PNG/GIF/SVG는 Filee처럼 확장자로 분류해 원본을 유지하므로 손상된 원본을 별도로 검증하지 않는다. ImageIO와 ImageMagick의 색상·압축 결과는 바이트가 다를 수 있다.
- GFM은 병합 셀과 중첩 표의 원래 레이아웃을 표현하지 못하므로 텍스트를 읽기 쉽게 펼친다. HWP의 쪽 레이아웃·floating object 위치와 머리말 변경의 페이지 배치는 재현하지 않는다.
- r2의 equationScriptVerbatim/텍스트 일치도는 LaTeX 변환으로 낮아질 수 있다. 표 캡션과 머리말을 추가해 원문 순서도 바뀐다. 한글 수·원문 n-gram 보존율과 함께 보아야 한다.
- 병합한 엔진을 포함한 전체 테스트를 실행했다. 외부 도구나 C# 기준선이 없는 테스트는 기존 조건에 따라 건너뛰었으며 자세한 조건은 테스트 로그에 남겼다. 별도 이미지 포맷 전체 조합이나 실제 한글 앱에서의 시각 비교는 이 표본 검증에 포함하지 않았다.


소요 시간은 Debug helper의 로컬 1회 실행값이다. 새 외부 프로그램·SwiftPM 의존성은
추가하지 않았다. 앱 설치, 사용자 앱 데이터, .NET·NuGet 설치 경로는 수정하지 않았다.

내부 공용 API로 EbookFiles.ImageFailure, dataUri(_:_:), markdownImages(_:_:_:),
HwpEquationConverter.toLatex(_:), HEquation과 HHeaderFooter.startBlockIndex를 추가했다.
writer의 기존 진입점 시그니처와 NDJSON 계약은 유지했다.
