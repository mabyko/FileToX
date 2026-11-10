# FileToX

[English](README.md) | [한국어](README.ko.md) | [日本語](README.jp.md)

FileToXは、[Filee](https://github.com/KnifeLemon/Filee)から着想を得て作ったMac専用のファイル変換アプリです。ファイルをドロップし、変換先の形式を選ぶだけで使えます。

SwiftUIとAppKitで開発し、Apple Silicon M1以降（arm64）、macOS 15以降に対応しています。Intel Mac・Rosettaでの実行と検証はサポート対象外です。初期言語は英語で、韓国語と日本語にも対応しています。

## 20秒で見るFileToX

[![FinderでOptionキーを押してPNGをドラッグし、JPGにドロップするFileToXのデモ](docs/media/filetox-demo.gif)](docs/media/filetox-demo.mp4)

[20秒の紹介動画を見る](docs/media/filetox-demo.mp4) · FinderのOptionドラッグを実際に撮影した、英語字幕付き・音声なしの動画です。

FileToXをメニューバーで実行したまま、FinderでファイルをドラッグしてからControl（⌃）キーを押します。円形メニューの変換先にドロップすれば変換できます。アプリのメインウィンドウは閉じておけます。**設定 → 呼び出し**でControl・Option・Shift・Commandを組み合わせ、文字・数字・ファンクションキー・矢印キー・スペースを追加できます。**保存**すると、このMacで設定が維持されます。有効なmacOSシステムショートカットやFinderのドラッグ操作と重なる場合は警告を表示します。他のアプリが登録したショートカットは検査対象に含まれません。

## 機能

- Finderでドラッグしながら設定した呼び出しキー（初期値はControl）を押すか、アプリのホームでファイル・フォルダとプリセットを選んで実行するか、円形の変換メニューを開けます。
- 171形式と23のエンジンで、画像・文書・動画・音声・アーカイブを扱えます。
- プリセットと円形ツールバーを編集し、変換したファイルの保存先を指定できます。
- 進捗の確認、キャンセル、失敗した変換の再試行、最近の変換の確認ができます。
- 英語・韓国語・日本語を選び、macOS標準のカラーピッカーでアクセント色を変更できます。
- 元のファイルを保護し、名前の衝突と複数の出力を処理します。

## アプリの画面

![ファイル選択と最近の変換を表示するFileToXのホーム画面](docs/images/filetox-home.png)

<table>
<tr><th>円形の変換メニュー</th><th>テーマとアクセント色</th></tr>
<tr><td width="40%" align="center"><img src="docs/images/filetox-radial.png" width="340" alt="円形の変換メニュー"></td><td width="60%"><img src="docs/images/filetox-theme.png" width="620" alt="テーマとアクセント色"></td></tr>
</table>

ホームと円形メニューは、隔離したエンジンデータフォルダを使ったネイティブSwiftUI画面です。テーマ画面は以前の英語Releaseビルドで撮影しました。

## 使い方

1. ホーム画面にファイルをドロップするか、ファイル・フォルダを選びます。
2. ホームでプリセット・ファイルツールを選んで実行するか、円形メニューを開きます。**すべての出力形式**から変換先を選ぶこともできます。
3. 元のファイルと同じフォルダ、または指定した出力フォルダで結果を確認します。

初回起動時にFinderのドラッグ操作の検出で使用するアクセシビリティの設定ガイドが表示され、システム設定から戻るとアクセス権を確認します。**後で**を選ぶとホームで変換を続けられ、**呼び出し → 設定方法を見る**からガイドを開き直せます。ネイティブ変換コンポーネントを同梱しており、.NETランタイムは使用しません。

登録されたすべての形式間で変換できるわけではありません。変換経路の探索が入力とエンジンの状態から利用可能なプリセット・出力形式を判断します。読み取り専用の58形式は出力候補に表示しません。未導入のエンジンやmacOSで利用できない経路には理由を表示します。

標準バンドルには内蔵ライブラリとrhwp・7-Zip・FFmpegを含みます。**変換エンジン**の管理対象エンジン欄から、固定バージョンのarm64 Pandoc・LibreOffice・CalibreをFileToX専用にダウンロードできます。インストール前にサイズとSHA-256を検証し、進捗表示とキャンセルに対応します。既存のエンジンフォルダは保持し、**外部エンジンの実行ファイル**で指定したコピーを優先します。指定したFFmpegのコピーは同梱版より優先されます。Ghostscriptはシステムのインストールまたは指定したコピーを使います。終了時は進行中のダウンロードをキャンセルして後処理を待ちます。中断したダウンロードの再開には対応していません。

変換前に、選択したFFmpegに必要なエンコーダーと出力形式が含まれるか確認します。不足している機能をエラーに表示し、既存の出力を保持します。下記の固定ソースからApple Silicon用FFmpegをビルドできますが、管理対象のダウンロードにはまだ含めていません。

PDFからEPUB・FB2・HTMLZ・TXTZ・ODTへの変換では、テキストとスキャン画像をページ順に保持します。テキストとスキャンが混在する文書や既存のOCRテキストにも対応します。不可視のOCRテキストだけを持つページは、ページ全体の描画も画像として保持します。テキストだけのPDFは従来の経路を使い、空白ページだけを理由に画像経路へ切り替えることはありません。これらの形式はスキャンページを画像として保持し、認識した文字は追加しません。TXTはスキャンや画像などテキストのないページをmacOSの文字認識（Vision）で読み取ります。認識言語はMacの言語順で最初の日本語・中国語・韓国語と英語で、読み取れる文字がない場合だけ失敗します。

出力は各出力先フォルダの非表示作業フォルダに書き込み、結果ごとに確定します。Overwriteでも元ファイルは保護し、名前が衝突した場合は初期設定で新しい名前を選びます。複数の出力の確定が途中で失敗しても、確定済みの結果を正しく報告します。バッチ全体を一括で巻き戻す原子性は保証しません。アプリのデータは`~/Library/Application Support/FileToX/{core,engines,tmp}`に分けて保存します。

<details>
<summary>開発・ビルド手順と検証記録</summary>

## ビルドと実行

Xcode 27 / Swift 6.4、XcodeGen 2.46以降を使います。ビルドスクリプトはPython 3の標準ライブラリを使用し、同梱FFmpegのビルドにはCMakeとpkg-configも必要です。アプリと変換helperはSwiftとネイティブライブラリでビルドし、.NET SDK・ランタイム・NuGetの復元は不要です。

最初のアプリビルド前に新しい作業フォルダでFFmpegを一度ビルドし、以後は検証済みバンドルを再利用します。

```sh
python3 Tools/build-ffmpeg.py --work "$PWD/build/ffmpeg" --jobs 6
xcodegen generate
xcodebuild -project FileToX.xcodeproj -scheme FileToX -configuration Debug \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 -derivedDataPath build/DerivedData build
open 'build/DerivedData/Build/Products/Debug/FileToX Dev.app'
```

Xcodeはルートの`Package.swift`にあるエンジン・Core製品を使用し、Swift helper・PDFium・同梱ツールを署名して組み込みます。アプリ・helper・テストはarm64のみを対象とし、ダウンロードツールはx64を拒否します。初回に固定バージョンのlibwebp・libjxlソースを取得し、rhwp・7-Zipは検証済みキャッシュがない場合だけ取得します。LibRaw・libjpeg-turbo・OpenJPEGのソース、元のuniversal PDFium dylib、arm64専用Skia SVG静的ライブラリを保持します。staging時にPDFium・同梱ツールからarm64のみを抽出して署名し、検証済み原本は変更しません。Skiaは限定した基本図形に使用し、その他のSVG機能とベクターPDFにはCoreSVGを使います。出典とライセンス告知を保持します. 固定されたlibavif 1.4.2・libaom 3.14.1の静的ライブラリを使うarm64の`FileToXAvifEncoder`と、そのライセンス告知も同梱します。

```sh
swift build -c release --product FileToXAvifEncoder
swift build -c release --product FileToXEngine
python3 Tools/fetch-optional-engines.py --help
```

stagingはバンドル直下と`bin`の許可リスト外のファイル、およびバンドル内のシンボリックリンクを拒否し、`ffmpeg`と`ffprobe`の2実行ファイル、ライセンス告知、`BUILDING.txt`だけを組み込みます。ローカルのビルドパスを含む出典記録はローカルのビルド成果物に残します。

FFmpegのレシピは新しい作業フォルダに固定ソースから必要なコーデックとAV1ソフトウェアデコーダーをビルドし、`ffmpeg/bin/{ffmpeg,ffprobe}`、実行ファイルとソースのZIP、出典情報を生成します。アプリのstagingは既定で`build/ffmpeg/ffmpeg`を使い、宣言されたバージョン・プラットフォーム、固定ソース一覧、バンドル自身の出典情報に記録された実行ファイルのハッシュ、告知ファイルの存在を確認してから組み込みます。これは内部整合性の確認で、ソースZIPやレシピのハッシュは検査せず、バンドルの出所を認証するものでもありません。別の場所にある検証済みビルドを使う場合は、Xcode実行時に`FILETOX_FFMPEG_BUNDLE`をその`ffmpeg`フォルダに設定します。システムのインストールや管理対象のダウンロード設定は変更しません。

```sh
FILETOX_FFMPEG_BUNDLE="$PWD/build/ffmpeg-new/ffmpeg" xcodebuild -project FileToX.xcodeproj -scheme FileToX -configuration Debug -destination 'platform=macOS,arch=arm64' ARCHS=arm64 -derivedDataPath build/DerivedData build
```

DebugのバンドルIDは`forked.filetox.local.dev`、Releaseは`forked.filetox.local`です。個人設定はGitの対象外となる`Config/Local.xcconfig`に保存します。Debug・Releaseの既定値はローカル用のad-hoc署名です。arm64 Releaseは既存チームの開発証明書による実際のXcodeビルド、deep/strict署名検証、およびリポジトリと.NET SDKへのアクセスを拒否した再配置実行23項目を通過しました。Developer ID署名・公証は未検証です。検証環境はM2 Max/macOS 27で、M1実機やmacOS 15での実行結果ではありません。範囲と残る差異は[最新の検証記録](docs/design/engine-differential-triage.md#remaining-work-integration-2026-10-26)に記載しています。

## 対応していない変換

次の変換先は一覧に出ないか、ファイルの内容によりエラーで終わります。元のアプリ（Filee）でも失敗していたもので、FileToXで外したのはPDBの書き出しだけです。

| 変換 | 動作 | 理由 |
| --- | --- | --- |
| 画像・PDF・SVG・CAD・文書 → 音声形式 | 選択できない | 元のファイルに音がありません。音声は動画・音声からのみ作ります。 |
| PDB（PalmDoc）への書き出し | 選択できない | Windows-1252の文字しか入らず、韓国語・日本語・絵文字が壊れます。PDBの読み込みはできます。 |
| 動画・音声 → TXT以外の文書（DOCX・MDなど）への文字起こし | 非対応 | 文字起こしはTXTだけです。動画 → 文書・画像は静止フレームの画像になります。 |
| 動画・音声 → TXT（macOS 15） | 選択できない | 文字起こしはmacOS 26以降のデバイス上の音声認識を使います。 |
| 音声認識の言語がひとつもないMacでの動画・音声 → TXT | 「No speech recognition language is installed」エラー | 設定で必要な言語をダウンロードします。 |
| 話し声のない動画・音声 → TXT | 「No speech was recognised」エラー | 音楽・効果音・無音は文字になりません。字幕トラックは読みません。 |
| 文字のない画像・スキャンPDF → TXT | 「The PDF contains no text」エラー | 文字レイヤーも認識できる文字もありません。文字のある画像・スキャンはOCRで読みます。 |

文字起こしとOCRの制限: 文字起こしの言語は、**設定 → 変換エンジン → 音声認識の言語**でダウンロードしたmacOSのモデルの中から選びます。複数ある場合は、ファイル冒頭の45秒を最もよく聞き取れる言語で全体を文字起こしします。インストールされていない言語は選べず、途中で言語が変わってもひとつの言語で聞き取ります。変換中にモデルはダウンロードしません。話者の区別と時刻はありません。OCRは縦書き、斜めに傾いたページ、手書き、第一言語と異なる日中韓の文字を保証せず、表を表として復元しません。

## 検証

```sh
swift test
xcodebuild -project FileToX.xcodeproj -scheme FileToX -configuration Debug \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 -derivedDataPath build/DerivedData test
python3 -I Tools/engine-compare/test_harness.py
python3 -I Tools/test-engine-entitlements.py
```

実際のhelperを使う統合テストの前に、helperをビルドしてください。見つからない場合は、そのテストだけをスキップします。別のhelperを使うには`FILETOX_TEST_HOST`でパスを指定します。実エンジンのサンプルは次のスクリプトで再現できます。作業フォルダには新しい絶対パスを指定してください。

```sh
FILETOX_SMOKE_HOST="$PWD/build/DerivedData/Build/Products/Debug/FileToX Dev.app/Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine"
python3 Tools/engine-smoke.py "$FILETOX_SMOKE_HOST" "$PWD/build/smoke-new"
python3 Tools/engine-optional-smoke.py "$FILETOX_SMOKE_HOST" "$PWD/build/optional-smoke-new"
```

以前のアプリ検証ではApple siliconで、Xcodeテスト32件、Swift Packageテスト12件、内蔵エンジンの検証22件（実変換20件・選択判定2件）、追加エンジン・動画・音声・処理中のキャンセル・添付画像の衝突を含むサンプル11件が成功しました。Swiftとの通信でも、PNG→JPG、PDF結合→複数PNG、不明な形式のファイル・フォルダ→ZIP→展開、履歴を確認しました。実行中のアプリでは、円形メニューのJPGクリック→結果生成→最近の履歴を確認しました。実際のFinder Optionドラッグでは、遅い動き、元ファイルの保持、ドロップ後のFinderのフォーカス維持を確認しました。韓国語のHWP・DOCXから生成したPDFのテキスト抽出とPNG描画も確認しています。英語・韓国語・日本語の切り替えは、実行中のアプリとhelperにすぐ反映されます。標準カラーピッカーで選んだ色の再起動後の保持、組み込みプリセット名の翻訳、ユーザーが付けた名前の保持も確認しました。

**設定 → 監視フォルダ**で入力フォルダとプリセットを選び、ルールを有効にして保存します。**監視中**になってからファイルを追加してください。起動時に存在するファイルは変更せず、アプリの実行中に新規・変更ファイルを処理します。出力先の既定値は`converted`で、原本は保持します。選択すると、変換に成功し変更されていない原本を`originals`へ移動します。パッケージ内部と一時ダウンロードフォルダは除外します。3秒の安定待ちはヒューリスティックです。長い書き込み停止がある場合は、完成したファイルをatomic renameで渡してください。スキャンは10,000項目、ジョブは入力128件までです。

すべての形式の組み合わせ・コーデックを検証したわけではありません。このマシンにはGhostscriptがありません。システムのFFmpegには一部のエンコーダーがありませんが、別途固定ソースから作成したビルドでは、以前失敗したAMR・OGG・OGVの21件、メディアテスト35件、AV1入力の変換が成功しました。 [メディアとスキャンPDFの検証記録](docs/design/engine-differential-triage.md#media-codecs-and-original-scanned-pdf-fallback-2026-10-27)。ログイン項目と通知は実装済みですが、実際のログアウト・ログイン後の自動起動と通知配信は未検証です。外部exFAT・SMBボリューム、配布用公証、TCCの再起動時の動作も未検証です。

2026-10-27〜28の更新では混在PDFの内容、位置情報が欠けたスライドの表・結合セルの位置・グループの拡大率、FB2のテキストボックスを補完しました。PMLは韓国語・日本語などのBMP文字をエスケープで保持し、PNGの縮小とパレット化を無効にします。非BMP文字は明示的に拒否します。SVGの限定した横書き文字は描画された輪郭を保ち、PDFの検索・選択とTXT抽出に対応します。複雑な文字、display・visibility・opacityの設定で非表示にした文字や切り抜かれた文字などは輪郭のみとし、文書への変換では編集可能なSVG文字ではなくページ画像を保持します。AVIFはImageIOの色・アルファの標本誤差が両方ゼロなら追加エンコードを省略します。短いTS/M2TSの高速シークで空画像が返った場合に先頭から一度再試行する動作も維持します。

SVGの文字の後に描画したものが、その文字の全部または一部を覆う可能性がある場合は、不透明・半透明を問わず検索用の文字を追加しません。領域を測定しない描画（参照・CoreSVGが配置する文字・入れ子のviewport・filter・marker・CSS変換）が後に続く場合も同様です。覆われた輪郭はPDFのベクター内容に残るため、図形で隠す操作は引き続き文字の削除ではありません。PML画像参照には実在するファイルが必要で、名前にはASCII英数字・下線・ハイフン・ピリオドを使用し、先頭のピリオドを避け、小文字の`.png`拡張子を付けます。

動画の長さを修正する前の2026-10-29 PDF・SVGレビュー時点の全テストは、**エンジン793件（15 skip）・Core18件、失敗0件**です。新しい通常ReleaseビルドでhostとAVIF helperを作成しました。その時点の新しいDebugアプリと別途コンパイルした実際のAppModelで、ファイル選択・設定保存・同梱AMR変換・キャンセル・OGG再試行・履歴・原本保持を確認しました。アプリのMach-Oはすべてarm64で、ad-hoc署名検証に成功し、Homebrewへの動的リンクはありません。実際のマウス・ダイアログ操作とXcodeホストのXCTest実行は再検証していません。

そのPDF・SVGレビュー時点のhostによる849件は**829件完了・20件失敗**です。残る失敗は音声トラックなし14件・抽出可能な文字なし6件で、すべての事例が直前の最終状態を維持しました。前回より前から成功していた786件と、前回に回復した43件も引き続き完了します。harness・検査エラーは0です。同じ閾値・判定方針による厳密なC#比較は**484 PASS / 260 WARN / 105 FAIL**です。C#では失敗し現在は成功する43件も状態の不一致としてFAILに含め、免除していません。委任した実装の検証と比べ、PDB→RBは埋め込み画像の類似度で再びFAILとなり、LRF→HTMLZはWARNからPASSとなりました。どちらの経路も今回のレビューでは変更していないため、修正の成果とは数えません。105件のFAILのケースIDは2026-10-28の最終比較とすべて同じです。比較用のPDF・SVG事例は新しい図の層や被覆の規則を通りません。変換完了と出力の同等性は別の結果です。

そのPDF・SVGレビュー時点のhostによる44件の変換が、出力テキスト・順序・画像参照・デコードの検査に成功しました。以前の混在PDF・既存OCR・空白ページ・SVGの26件に、ベクターのグラフ・インライン画像・フォームの文字があるテキストページのDOCX・HWPX・EPUB・FB2・HTMLZ・TXTZ・ODT・TXT、ステンシルマスクのページのDOCX・EPUB、覆われたSVG文字のPDF・TXTに加え、ルートの線属性の継承・相対画像座標のPDF・TXT 6件を確認しました。可視テキストのあるPDFページがベクター図形・シェーディング・インライン画像・ステンシルマスクを描く場合、文字を除いて描画したページ1枚としてそれらを保持し、紙面上の元の位置で文字の背面に置きます。リフロー形式ではそのページの文字の前に置かれます。文字はテキストとして一度だけ残り、TXTは文字のみを含み、白い紙だけを残す塗りは画像を追加しません。このようなページの他の画像は元のバイトではなく150dpiの描画の一部となり、当時の実装は画像層からすべての文字オブジェクトを削除していました。下記のPDF保持修正は抽出から欠けたグリフを扱います。縦書き全体を読めないという以前の説明は不正確でした。ページ画像は再描画した内容であり、原本の画像バイト・色プロファイル・透明度の保持ではありません。完全なSVG/C#同等性、新たなOCR、全形式・コーデックの組み合わせを確認したわけではありません。根拠と残る差異は[最終追加検証](docs/design/engine-differential-triage.md#remaining-work-final-verification-2026-10-28)と[テキストページの図・覆われたSVG文字](docs/design/engine-differential-triage.md#priority-one-integration-review-2026-10-29)を参照してください。その時点のPDFテキスト検証は既存出力とバイト単位で一致し、連続5回すべてで0.84秒の目標を満たしました（0.673〜0.772秒、中央値0.701秒）。それ以外の以前の開発証明書・再配置・性能測定は過去の記録とし、実機M1/macOS 15・外部ファイルシステム・TCC・ログイン/通知・公証は未検証です。

2026-10-29の動画の長さの修正では、低速入力のTS・M2TS・MPG・MXFの最終フレームの表示時間を補い、低い平均値に隠れた短い色の変化には入力の公称フレームレートも反映します。元のICNSのM2TS・MPG・MXFは、ファイルの長さとデコードした表示時間がともに0.1秒です。現在のソースの集中テスト**56件**と実変換**33件**が成功し、849件は**829件完了・20件失敗**、harness・検査エラーは0です。同じ基準の厳密なC#比較は**482 PASS / 241 WARN / 126 FAIL**で、公称フレームレートの項目差によるFAILが22件増えました。今回変更していない電子書籍経路でも2件の判定が変わりましたが、修正の成果とは数えません。変換完了と同等性は区別します。フレーム単位で表せない0.13秒は約0.1668秒に切り上げられ、極小MPGの推定ファイル長は実際の表示時間より短い場合があります。上記の全テスト・アプリ/AppModel・PDF性能は以前のPDF・SVGレビュー時点の結果で、今回のソースでは繰り返していません。[動画の長さの検証](docs/design/engine-differential-triage.md#slow-media-duration-verification-2026-10-29)。

PalmDoc（`.pdb`）は2026-11-06から読み込みのみに対応します。Windows-1252の文字しか保存できず、韓国語・日本語・絵文字を書き出せなかったため、以前の出力は文字を`?`に置き換えずに保存を拒否していました。PDBを対象に保存したプリセットは一覧に残り、利用できないと表示されます。DWG出力はR2010以降の内部空き領域の構造を使い、ページ数にはページマップ自身も含めます。[従来の品質差と内容欠落の検証](docs/design/engine-differential-triage.md#legacy-quality-loss-verification-2026-10-29)。

2026-10-29のDWG・PDB修正ソースでは、**エンジン800件（15件skip）・Core 18件、失敗0件**です。849件の再変換は**822件完了・27件失敗**で、従来の20件に文字欠落を防ぐPDBの拒否7件が加わりました。他の経路の完了状態は変わらず、harness・検査エラーは0件です。同じ基準での厳密なC#比較は**474 PASS / 241 WARN / 134 FAIL**です。新たなFAIL 8件は上記PDBの拒否7件と、変更していないPDB→SNBの生成画像による判定変動1件です。DWGの独立した読み戻し、新しいDebugアプリの署名・arm64構成・AppModelの変換・取消・再試行・履歴も検証を通過しました。実際のGUI操作・XcodeホストのXCTest実行、実機M1/macOS 15と配布の検証は未実施です。[現在の検証と制限](docs/design/engine-differential-triage.md#legacy-quality-loss-verification-2026-10-29)。

2026-11-02のPDF保持修正では、抽出できないグリフをページ画像に残し、合字や文字クラスタの後で欠けていた文字を回復し、極端な座標によるエンジン終了を防ぎます。入れ子のフォームと一部だけ抽出できる文字オブジェクトも検証しました。最終ソースは**エンジン812件（15件skip）・Core 18件、失敗0件**、**リッチ変換94件・境界事例8件を通過**しました。849件の状態はすべて**822件完了・27件失敗**を維持し、厳密比較も**474 PASS / 241 WARN / 134 FAIL**で事例ごとの判定変更はありません。新しいDebugアプリの署名・arm64構成・AppModelフローも検証を通過しました。画像は150dpiで、斜めや重なる文字の判別、原本画像の解像度と合字後の配置には制限が残ります。[2026-11-02のPDF検証と制限](docs/design/engine-differential-triage.md#pdf-text-preservation-integration-2026-11-02)。

2026-11-06のPDF修正は、抽出した単語と各グリフの文字を照合し、斜めや重なる文字で失われていたグリフを保持します。ハングル音節や省略記号の互換分解もすべて数えます。抽出できないグリフのため描画層を追加するページでは、回転がなく、合成も不要な独立した写真の元バイトと解像度を保持します。マスク・グラフィックス状態・クリップ・フォーム・画像変形・重なり・ページ外の画像や回転ページは、安全のため合成画像に残します。保持するグリフは150dpiの画素で、重なる線の小さな断片、合字の配置、従来からある180度ページの文字と画像の座標差には制限が残ります。 描画層を追加しない通常の画像抽出経路には、従来のマスク・クリップの制限が残ります。

最終ソースは**エンジン821件（15件skip）・Core 18件、失敗0件**、**リッチ/TXT変換142件・境界事例25件・レビュー再現変換36件**を通過しました。849件の状態はすべて**822件完了・27件失敗**を維持し、厳密比較は同じFAIL集合の**474 PASS / 241 WARN / 134 FAIL**です。新しいDebugアプリの署名・arm64構成とAppModelフローも通過し、DOCX・EPUBで元の400×400写真と未抽出グリフの画像を確認しました。[最新のPDF検証と制限](docs/design/engine-differential-triage.md#pdf-geometry-integration-2026-11-06)。

2026-11-06に厳密比較のFAIL 134件を再分類した結果、C#より悪化した事例は見つかりませんでした。C#が失敗しSwiftが完了した43件、動画の最終フレーム表示時間の修正30件、PDBの韓国語拒否7件、スライド文字の保持6件、既存の48件です。画像・PDF・SVG・CADに表示されていた音声出力18種類と動画のTXT出力は結果を得られないため経路計画から除外し、形式一覧と円形メニューでは無効になります。PDF→TXTはテキストのないスキャン・画像ページをmacOSのVisionで読み取るため、画像・コミックのTXTも再び利用できます。300dpiで作成した韓英混在6ページのスキャンでは単語再現率96.5%、文字類似度97.6%、1ページ約0.33秒でした。全体の検査は**エンジン827件・Core 18件、失敗0件**、849件は**822件完了・27件失敗**（経路なし15件・PDB 7件・文字のない画像/スキャンのTXT 5件）で、他の834件の状態は変わりません。厳密比較は、変換前に拒否されエラーキーが変わった15件により**460 PASS / 240 WARN / 149 FAIL**です。韓国語のPDBには対応していません。[再分類・対象の除外・OCR](docs/design/engine-differential-triage.md#unreachable-targets-2026-11-06)。

すべてのCalibre変換には、シンボリックリンクを解決した`ebook-convert`の隣に`calibre-debug`がある完全なインストールが必要です。子プロセスの内部API補完は固定Calibre 9.15.0で目次スタイル・TCR・PMLの保持を検証しており、他のバージョンは再検証が必要です。別途Pythonのインストールは不要です.

## ソースと設計

開発時の参考は[KnifeLemon/Filee](https://github.com/KnifeLemon/Filee)のコミット`21fdd05ef7181b032ed83ec895cc9bbc4b198985`です。現在のCore・host・エンジンは`Sources/Engine`、アプリ向けCoreパッケージは`Sources/Core`にあります。上流のライセンスと告知は`docs/upstream`に保管し、現在のビルドはFileeのC#プロジェクトを参照しません。

- [全形式の一覧](docs/formats.md)、[全体設計](docs/architecture.md)
- [通信仕様](docs/design/host-wire-v1.md)、[hostの実装](Sources/Engine/Host/Host.swift)
- [UI設計](docs/design/swiftui-port.md)、[パッケージング・署名](docs/design/macos-packaging.md)
- [Claudeによる設計レビュー](docs/design/review.md)、[エンジン実装・検証状況](docs/design/engine-differential-triage.md)

以前の会話の試案は`docs/archive/pre-filetox/`に保存しています。ノッチ棚、ファイルの保管・移動・コピーは現在の対象範囲に含みません。

</details>

## 謝辞

FileToXは、[Filee](https://github.com/KnifeLemon/Filee)から着想を得て作ったMac専用のファイル変換アプリです。SwiftUIとAppKitでmacOSに合わせて開発した独立プロジェクトであり、Fileeの公式リリースではありません。

FileToXは[MITライセンス](LICENSE)で公開します。Fileeの[MITライセンス](docs/upstream/Filee.LICENSE)と[外部コンポーネントの利用表記](docs/upstream/Filee.THIRD-PARTY-NOTICES.md)を保持します。MITは各外部エンジンのライセンスに代わるものではありません。カメラRAWは[LibRaw](https://www.libraw.org) 0.22.2で読み込み、LibRawは[CDDL-1.0](docs/upstream/LibRaw.LICENSE)([利用表記](docs/upstream/LibRaw.THIRD-PARTY-NOTICES.md))で使用します。変更していないソースは`Vendor/LibRaw`にあります。JPEGの書き出しと非可逆圧縮DNGの読み込みには[libjpeg-turbo](https://libjpeg-turbo.org) 3.2.0をIJGライセンス([ライセンス](docs/upstream/libjpeg-turbo.LICENSE)、[利用表記](docs/upstream/libjpeg-turbo.THIRD-PARTY-NOTICES.md))で使用します。本ソフトウェアは一部Independent JPEG Groupの成果に基づいています。変更していないソースは`Vendor/libjpeg-turbo`にあります。実際のバンドルの利用表記はhelperの`Contents/Resources/Notices`に含めます。 PDFのラスター出力は旧C#版と同じ[同梱PDFium](Vendor/PDFium/README.md) 147.0.7690.0（arm64配布コピー）を使用します。[BSD-3ライセンス](docs/upstream/PDFium.LICENSE)と[同梱コンポーネントの利用表記](docs/upstream/PDFium.THIRD-PARTY-NOTICES.md)をhelperに含めます。
