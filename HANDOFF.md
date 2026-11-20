# HANDOFF — TS2TPSCamera

Tormented Souls 2 を TPS 視点にする UE4SS Lua MOD。最終更新 2026-11-07。

## 構成

| パス | 役割 |
| --- | --- |
| `TS2TPSCamera/Scripts/main.lua` | 中核。カメラ調停、入力（視点・WASD・十字キー・数字キー）、native/BP フック |
| `TS2TPSCamera/Scripts/camera_math.lua` | 純粋計算（単体テスト対象） |
| `TS2TPSCamera/Scripts/config.lua` | 設定スキーマと既定値（hidden = F1 一覧に出さない） |
| `TS2TPSCamera/Scripts/settings_model.lua` | 設定画面の行モデル |
| `TS2TPSCamera/Scripts/store.lua` | `settings_values.lua` の保存/読込 |
| `TS2TPSCamera/Scripts/ui.lua` | F1 設定画面、カメラ位置画面、フォント統一、日英表示 |
| `TS2Probe/` | 調査用 MOD（通常は不要） |
| `Install-TS2TPS.ps1` | 導入（バックアップ・ハッシュ照合付き、ゲーム終了が前提） |
| `Build-Release.ps1` | 配布 zip（`release\TS2TPSCamera-v<版>.zip`）。MOD 本体と `dist\` の文書だけを入れ、個人パス・プレースホルダ・版数の不一致で作成を拒否 |
| `dist/` | 配布用の README（英・日）、LICENSE（TetuTarako）、CHANGELOG、`NEXUS-page.md`（Nexus 用の文面。zip には入らない） |
| `tests/` | `python tests/run_tests.py`（lupa 必須、139 チェック） |
| `research/` | 調査メモ `PHASE0-NOTES-ja.md`、抽出アセット、ABP のダンプ |
| `tools/KismetDump` | BP バイトコードのダンプ（net9.0） |

操作・導入・無効化は `README-ja.md`。調査の経緯と仕組みは `research/PHASE0-NOTES-ja.md`。

## 確認済み（ユーザーが実機で確認）

- TPS 視点、マウス/右スティックでの 360 度視点、左スティックのカメラ基準移動。
- 構えた瞬間（と標的切替時）に敵へカメラが向き、その後は視点を自由に動かせる。
- 強制カメラ（ムービー・パズル等）の尊重。終了時はゲームが固定カメラを返した瞬間に TPS へ直接ブレンド（`effective_special` / `S.returning`）。
- 目のマークの調査中（`bIsInsideInteraction` のみ）、はしご（`IsClimbing` / `CurrentLadder`）、捕まり中は TPS 維持。
- アイテム調査画面の右スティック回転（`IA_Inv_RotationStick` は pawn の `AxisHorizontal/Vertical` を呼ぶ。操作停止中・ポーズ中は遮断しない）。
- F1 設定画面とカメラ位置画面（操作、即時反映、保存、日英表示、フォント統一、文言・レイアウト）。
- 設定画面表示中にアイテム画面・メニュー画面が出ない。
- TPS 中に十字キーでキャラが移動せず、歩行モーションも再生されない。
- WASD が左スティック同様に動く。数字キーの武器切替が元のゲーム通り。
- 固定カメラ状態（TPS OFF・強制カメラ中）で、パッド・キーボードとも元の操作に戻る。
- 台車などを押し引きしている間もカメラを自由に動かせる（`BP_PushSystemComponent.CurrentPushable` で判定。pawn の `IsPushingObject` は変化しない）。
- ロード後の視点: 新しいキャラ／コントローラーを検出して設定をやり直し、背後・既定の上下角へ戻す（`S.known_pawn` / `S.settle_until`。ユーザー確認「だいたいOK」）。
- 単体テスト 139 チェック合格。

## 実機未確認（直近に追加）

- パッド RS 押し込みでカメラを背後へ（`recenter_step`）。ログ `camera reset behind the character`。
- 懐中電灯を LS に移す: `IA_InGame_CenterShortcut`（RS→LS）と `IA_InGame_OpenDebugMenu`（LS→無効）を InputMappingContext と `EnhancedPlayerInput` のマッピングで書き換え。ログ `key remap` / `pad button remap ON/OFF`。TPS 解除中は元に戻す。
- 移動中に自動で背後へ回す（`auto_recenter`、既定 OFF、速さ `auto_recenter_speed`）。
- F1 画面の構成（下記）と、全 14 行がスクロールなしで枠内に収まるか（文字幅は推定で、はみ出すと自動で小さくなる）。

## F1 設定画面の構成

`config.lua` の `group_order` = カメラ / 視点操作（パッド）/ 操作視点（マウス）。カメラ見出しの並びは「TPSカメラ（OFFで元の固定カメラ）」「カメラ位置変更画面を開く」「移動中にカメラを自動で背後へ回す」「自動で背後へ回る速さ」。パッドとマウスの反転は別設定（`pad_look_invert_x/y`、`mouse_invert_x/y`）。旧キー `invert_x` / `invert_y` / `pad_invert_y` は廃止（読込時に無視）。右スティック上下の向き入れ替えはコードに固定。フッターは A / Enter で決定、B / ESC / F1 で閉じる。文言は `settings_model.lua` の `footer_help`、レイアウトは `ui.lua` の `HEAD_H` / `ROW_H` / `FOOT_H`。

## 未確認・注意

- 全シナリオ（屋内外・廊下・ボス戦・QTE・押す動作）の通し確認。主要項目は確認済み。
- 全レベルでの見た目（背面の描画欠け、低い天井、狭い通路）。固定カメラ前提のため崩れる場所があり得る。
- カメラ位置画面の LB/RB 表記は「LB=手前 / RB=奥」だが動作は LB=奥 / RB=手前（ユーザー指定で表記のみ変更。動作を揃えるなら `ui.lua` の `CAMERA_INPUTS` の `cam_far` / `cam_near` を入れ替える）。
- ゲーム更新で壊れる可能性。`Install-TS2TPS.ps1` が実行ファイルのハッシュ不一致を警告する。
- セーブフォルダのバックアップは取っていない（MOD はセーブに触れない設計）。
- 英語表示は日本語に合わせて作ったが、英語ゲーム設定での実機確認は日本語ほど行っていない。

## 落とし穴（再開する人向け）

- BP 関数のフックはクラスロード後でないと登録できない → `hook_when_loaded` のリトライを使う。BP の post-hook は期待どおり発火しないことがある。native フックは確実。
- pawn の dpadX/Y を毎フレーム 0 にするだけでは移動は止まらない。`AddMovementInput` / `K2_AddActorWorldRotation` を無効化し、AnimBP の `Calculate*Direction` で移動フラグを落とす必要があった。
- 部屋切替時、ゲームの固定カメラ指示は `SetViewTargetWithBlend` で来る。`ViewTarget.Target` はブレンド終了まで変わらないので、ブレンド中は「ゲームにカメラを奪われた」と誤判定しないこと（`S.blend_until`）。
- 特殊状態フラグ（`bIsInsideInteraction` 等）はカメラが戻った後も約 1 秒残る。目のマーク調査は部屋カメラのまま `bIsInsideInteraction` だけを立てる（TPS を保持して固定する）。
- セーブのロードでキャラ／コントローラーが作り直される（オブジェクト名は同じでアドレスが変わる）。TPS 状態を引き継ぐとカメラ設定が新キャラに入らない。
- 台車は pawn の `IsPushingObject` が変化せず `PushSystemComponent.CurrentPushable` を見る。はしごは `ClimbSystemComponent.CurrentLadder`。
- アイテム画面の右スティック回転は pawn の `AxisHorizontal/Vertical` 経由。操作停止中・ポーズ中は遮断しない。
- `GetPlayerInput` は Lua から呼べない。入力停止は `DisableInput` を使う。
- Lua の `FRotator` は `pitch` が小文字。
- `Install-TS2TPS.ps1` は PowerShell から実行（bash 経由だと `-Mods A,B` が 1 つの文字列になる）。実行ポリシーで止まる場合は `-ExecutionPolicy Bypass`。
- ログ: `...\Binaries\Win64\ue4ss\UE4SS.log` の `[TS2TPS]` 行。

## 配布

- 0.9.0: 2026-11-07 公開（GitHub、Nexus mod 12）。
- 0.9.1（2026-11-20）: 次元の鏡で固定カメラに戻る／F1 が開かない不具合（残ったパズルフラグ `isInteractingWithPuzzleComp` を、`CurrentPuzzle`・`bIsInsideInteraction`・`isSolvingPuzzle` のどれかが立っているときだけ有効にした）と、暗闇の演出（`BPC_DarknessSystem.LoadMaterialToCameras` が `BP_RailCamera` のカメラにだけ付ける `DarknessSystem_Mat` を `FollowCamera` にも `AddOrUpdateBlendable` で付けた）を修正。ゲームの 2026年11月アップデート版（exe `FB761DAB...`）で確認。

### 0.9.0 の記録

- zip は作成・内容検証済み。**クリーン導入テスト済み（2026-11-07）**: 公式 experimental-latest の `UE4SS_v3.0.1-1217-g4fb9b615.zip` だけを入れ、配布 zip を README どおりに導入 → 起動、MOD 読込（`loaded v0.9.0`）、TPS ON、F1 設定画面、TPS の OFF/ON 切替、設定の保存まで動作。UE4SS のエラー行 `Failed to expose size of FObjectPtrProperty` は UE4SS 側のメッセージで MOD は影響なし。
- 未確認: 公式のタグ版 v3.0.0 / v3.0.1（2024年初め。`LoopInGameThreadWithDelay` が無い可能性）。再起動後の設定保持。ロード後の視点（この導入では未操作）。
- 開発環境の UE4SS は別ビルド（`LICENSE` の著作権表記が Narknon、`[HashTables]` ログあり）で、公式 experimental-latest でも同じように動くことを確認した。
- GitHub に載せる場合は `.gitignore`（`research/`、`backups/`、`tools/`、`release/`、`TS2Probe/` を除外）を使う。`research/` にはゲームから取り出した素材が入っているので公開しない。`dist/NEXUS-page.md` の GitHub URL は公開後に差し替える。
- 版を上げるときは `main.lua` の `VERSION`、`dist\` の README 2 つ、`dist\CHANGELOG.md` を揃える（揃っていないと `Build-Release.ps1` が拒否する）。

## 次にやるなら

- 全シナリオ（屋内外・廊下・ボス戦・QTE・押す動作）の通し確認とログ点検。
- LB/RB の表記と動作の整合。
- 部屋単位の見た目の崩れへの対処（必要な場所だけ）。
