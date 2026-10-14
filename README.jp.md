# FileToX

[English](README.md) | [한국어](README.ko.md) | [日本語](README.jp.md)

FileToXは、[Filee](https://github.com/KnifeLemon/Filee)から着想を得て作ったMac専用のファイル変換アプリです。ファイルをドロップし、変換先の形式を選ぶだけで使えます。

SwiftUIとAppKitで開発し、macOS 15以降に対応しています。初期言語は英語で、韓国語と日本語にも対応しています。

## 20秒で見るFileToX

[![FinderでOptionキーを押してPNGをドラッグし、JPGにドロップするFileToXのデモ](docs/media/filetox-demo.gif)](docs/media/filetox-demo.mp4)

[20秒の紹介動画を見る](docs/media/filetox-demo.mp4) · FinderのOptionドラッグを実際に撮影した、英語字幕付き・音声なしの動画です。

FileToXをメニューバーで実行したまま、FinderでファイルをドラッグしてからControl（⌃）キーを押します。円形メニューの変換先にドロップすれば変換できます。アプリのメインウィンドウは閉じておけます。**設定 → 呼び出し**でControl・Option・Shift・Commandを組み合わせ、文字・数字・ファンクションキー・矢印キー・スペースを追加できます。**保存**すると、このMacで設定が維持されます。有効なmacOSシステムショートカットやFinderのドラッグ操作と重なる場合は警告を表示します。他のアプリが登録したショートカットは検査対象に含まれません。

## 機能

- Finderでドラッグしながら設定した呼び出しキー（初期値はControl）を押すか、アプリでファイル・フォルダを選ぶと円形の変換メニューを開けます。
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

macOSで動作する英語のRelease版を撮影した画面です。

## 使い方

1. ホーム画面にファイルをドロップするか、ファイル・フォルダを選びます。
2. 円形メニューでプリセットを選ぶか、**すべての出力形式**から変換先を選びます。
3. 元のファイルと同じフォルダ、または指定した出力フォルダで結果を確認します。

初回起動時にFinderのドラッグ操作の検出で使用するアクセシビリティの設定ガイドが表示され、システム設定から戻るとアクセス権を確認します。**後で**を選ぶとホームで変換を続けられ、**呼び出し → 設定方法を見る**からガイドを開き直せます。変換ランタイムは同梱しているため、.NETを別途インストールする必要はありません。

登録されたすべての形式間で変換できるわけではありません。変換経路の探索が入力とエンジンの状態から利用可能なプリセット・出力形式を判断します。読み取り専用の58形式は出力候補に表示しません。未導入のエンジンやmacOSで利用できない経路には理由を表示します。

標準バンドルには内蔵ライブラリとrhwp・7-Zipを含みます。FFmpeg・Ghostscript・Pandoc・LibreOffice・Calibreは、システムに導入されたもの、または**変換エンジン → 外部エンジンの実行ファイル**で指定したコピーを使います。開発用ダウンロードツールで取得したコピーは、利用者の設定には自動登録しません。

出力は元ファイルと同じフォルダの非表示作業フォルダに書き込み、結果ごとに確定します。Overwriteでも元ファイルは保護し、名前が衝突した場合は初期設定で新しい名前を選びます。複数の出力の確定が途中で失敗しても、確定済みの結果を正しく報告します。バッチ全体を一括で巻き戻す原子性は保証しません。アプリのデータは`~/Library/Application Support/FileToX/{core,engines,tmp}`に分けて保存します。

<details>
<summary>開発・ビルド手順と検証記録</summary>

## ビルドと実行

Xcode 27 / Swift 6.4、XcodeGen 2.46以降を使います。ビルドには`Config/EngineHost.global.json`で固定した.NET SDK 10.0.401が必要です。`~/.dotnet`のSDKを使うか、`DOTNET_ROOT`にSDKのインストール先を指定してください。導入方法は[Microsoft公式ダウンロード](https://dotnet.microsoft.com/download/dotnet/10.0)を参照してください。

```sh
xcodegen generate
xcodebuild -project FileToX.xcodeproj -scheme FileToX -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build
open 'build/DerivedData/Build/Products/Debug/FileToX Dev.app'
```

Xcodeのビルド処理が上流ソースのハッシュを検証し、作業用コピーにパッチを適用してhelperを生成・署名・同梱します。初回ビルドではNuGetと固定バージョンのrhwp・7-Zipを取得します。ソースに変更がなければ、次回以降はキャッシュされた生成結果を使います。

```sh
Tools/build-engine-host.sh --rid osx-arm64 --configuration Debug
python3 Tools/fetch-optional-engines.py --help
```

DebugのバンドルIDは`forked.filetox.local.dev`、Releaseは`forked.filetox.local`です。個人設定はGitの対象外となる`Config/Local.xcconfig`に保存します。現在のDebug・Releaseはローカル用のad-hoc署名です。Developer ID署名と公証は未完了です。Intel向けのビルド指定はありますが、実行は未検証です。

## 検証

```sh
swift test
xcodebuild -project FileToX.xcodeproj -scheme FileToX -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData test
python3 -I Tools/verify-filee-vendor.py --selftest
python3 -I Tools/verify-filee-vendor.py
python3 -I Tools/import-filee-formats.py --check
python3 -I -m unittest discover -s Tests/Tools -v
```

実際のhelperを使う統合テストの前に、helperをビルドしてください。見つからない場合は、そのテストだけをスキップします。別のhelperを使うには`FILETOX_TEST_HOST`でパスを指定します。実エンジンのサンプルは次のスクリプトで再現できます。作業フォルダには新しい絶対パスを指定してください。

```sh
python3 EngineHost/smoke.py \
  "$PWD/build/engine-host/osx-arm64/Debug/FileToXEngine.app/Contents/MacOS/FileToXEngine" \
  "$PWD/build/smoke-new"
python3 EngineHost/optional-smoke.py --help
```

Apple siliconで、Xcodeテスト32件、Swift Packageテスト12件、内蔵エンジンの検証22件（実変換20件・選択判定2件）、追加エンジン・動画・音声・処理中のキャンセル・添付画像の衝突を含むサンプル11件が成功しました。Swiftとの通信でも、PNG→JPG、PDF結合→複数PNG、不明な形式のファイル・フォルダ→ZIP→展開、履歴を確認しました。実行中のアプリでは、円形メニューのJPGクリック→結果生成→最近の履歴を確認しました。実際のFinder Optionドラッグでは、遅い動き、元ファイルの保持、ドロップ後のFinderのフォーカス維持を確認しました。韓国語のHWP・DOCXから生成したPDFのテキスト抽出とPNG描画も確認しています。英語・韓国語・日本語の切り替えは、実行中のアプリとhelperにすぐ反映されます。標準カラーピッカーで選んだ色の再起動後の保持、組み込みプリセット名の翻訳、ユーザーが付けた名前の保持も確認しました。

上流Coreは154件成功・2件スキップ、パッチ適用後のCoreは164件成功・2件スキップです。Enginesは上流・パッチ適用後とも445件成功・3件失敗で、3件の失敗はこのマシンのFFmpegに必要なエンコーダーがないためです。追加した実エンジンテスト4件は、Pandoc・LibreOfficeがある環境で通ります。

すべての形式の組み合わせ・コーデックを検証したわけではありません。このマシンにはGhostscriptがなく、FFmpegにも一部のエンコーダーがありません。監視フォルダの自動変換、アプリ内でのエンジンダウンロード、ログイン項目はまだ接続していません。外部exFAT・SMBボリューム、Intel、配布用公証、TCCの再起動時の動作も未検証です。

## ソースと設計

開発時の参考は[KnifeLemon/Filee](https://github.com/KnifeLemon/Filee)のコミット`21fdd05ef7181b032ed83ec895cc9bbc4b198985`です。ファイル情報とSHA-256は`Vendor/filee-manifest.json`に、ビルド用パッチは`Vendor/Filee.patches/`に記録しています。`.reference/Filee`はカタログの再生成時にだけ必要です。

- [全形式の一覧](docs/formats.md)、[全体設計](docs/architecture.md)
- [通信仕様](docs/design/host-wire-v1.md)、[hostの実装](EngineHost/README.md)
- [UI設計](docs/design/swiftui-port.md)、[パッケージング・署名](docs/design/macos-packaging.md)
- [Claudeによる設計レビュー](docs/design/review.md)、[エンジン実装・検証状況](EngineHost/IMPLEMENTATION.md)

以前の会話の試案は`docs/archive/pre-filetox/`に保存しています。ノッチ棚、ファイルの保管・移動・コピーは現在の対象範囲に含みません。

</details>

## 謝辞

FileToXは、[Filee](https://github.com/KnifeLemon/Filee)から着想を得て作ったMac専用のファイル変換アプリです。SwiftUIとAppKitでmacOSに合わせて開発した独立プロジェクトであり、Fileeの公式リリースではありません。

FileToXは[MITライセンス](LICENSE)で公開します。Fileeの[MITライセンス](docs/upstream/Filee.LICENSE)と[外部コンポーネントの利用表記](docs/upstream/Filee.THIRD-PARTY-NOTICES.md)を保持します。MITは各外部エンジンのライセンスに代わるものではありません。実際のバンドルの利用表記はhelperの`Contents/Resources/Notices`に含めます。
