# Phase 0 調査メモ（2026-11-06）

## 環境
- ゲーム: `E:\program files\steamapps\common\Tormented Souls 2`、exe SHA-256 `6C71AB55...CB4F`（`TormentedSouls2-Win64-Shipping.exe`）
- IoStore は非圧縮・暗号化なし。`retoc to-legacy --version UE5_5 -f <名前>` で個別抽出できる（`research/extracted/`）。UE 5.4 以降。
- UE4SS v3.0.1 Beta（Subnautica 2 から複製）を `TormentedSouls2\Binaries\Win64` に導入済み（`dwmapi.dll` + `ue4ss\`）。導入記録: `research/install-record-*.json`
- バイトコード解析ツール（UAssetAPI 等）は未導入。`research/strings_of.py` で名前テーブルのみ確認している。

## 名前テーブルから分かったこと
- 主人公: `/Game/Characters/BP_TormentedSoulCharacter`（C++ 親 `/Script/TormentedSouls2.TormentedSouls2Character`）。`FollowCamera`（CameraComponent）を持つ。
  - 変数: `Current Camera Rotator` / `Last Camera Rotator`（移動基準向きの候補）、`NorthCamera`、`TankMode`、`IsRunningTankMode`、`bIsAnalogMovement`、`stickX/Y`、`lastStickX/Y`、`dpadX/Y`、`IsTrailerCameraActive?`
  - 狙い: `AimCurrentWeapon`、`CurrentTarget(s)`、`GetClosestTarget`、`DetectTargetsToLook`、`Rotate To Enemy`、`FDCTween_RotationToEnemy`、`CanRotateTarget`、`ChangeCurrentTarget`
  - 構成コンポーネント: `BPC_WeaponSystemComponent`、`BPC_PL_CustomMovementSystem`、`BPC_ClimbSystem`、`BP_PushSystemComponent`、`BPC_ShoulderLampSystem` ほか
  - デバッグ入力: `T` / `NumPadOne` / `NumPadTwo`（トレーラーカメラ）
- コントローラ: `TormentedSouls2PlayerController`（C++ 親 `TormentedSoulPlayerController`）。`SwitchMapTo*`/`SwitchTo*` で IMC を切り替える（InGame / Cinematic / Puzzle / POI / Inventory / Push / QTE …）→ 「通常ゲームプレイ中」判定に使える。`RightAxisHorizontal/Vertical`、`InjectAimInputIfNeeded`、`bUseGamepad` あり。
- `BP_CustomCamera`: Actor + `CineCameraComponent`「CineCamera」1 個のみ（FOV はコンストラクションスクリプトで設定）。
- `BP_RailCamera`: スプライン追従、`CameraCompensation`、`AutoNorth`、`CameraDistance`、`ActiveSuperFovCamera`、箱の `ComponentBeginOverlap` で切替。
- `BP_WeaponSystemComponent` / `E_TargetSystemModes` / `BPI_Target` は抽出済み（詳細は未解析）。

## 実機プローブ（TS2Probe）の使い方
ゲーム起動後、ロード済みの状態で:
1. `F8` … `snapshot-HHMMSS.txt` を MOD フォルダに書き出す（通常の部屋 / 構え中 / ムービー・パズル中で各 1 回）。
2. `F9` … 5 秒間、マウス/右スティック/左スティックの生入力値を `UE4SS.log` に出す。
3. `F10` … 8 秒間、カメラ回転・主人公回転・移動基準変数・ロックオン変数を 100ms ごとに記録。歩きながら視点切替（部屋の境目）をまたぐ／構える、の 2 パターンで実施。
- ビューターゲットの変化は常時 `UE4SS.log` に `[TS2Probe] VIEWTARGET changed ...` として記録される。
- ログ: `E:\program files\steamapps\common\Tormented Souls 2\TormentedSouls2\Binaries\Win64\ue4ss\UE4SS.log`
- スナップショット: 同 `ue4ss\Mods\TS2Probe\snapshot-*.txt`
- 外す場合: `ue4ss\Mods\TS2Probe\enabled.txt` を改名。UE4SS ごと外す場合は `Win64\dwmapi.dll` を削除。

---
# 静的解析の結果（BP バイトコード、ゲーム未起動）

## ツール
- `tools/KismetDump`: retoc で抽出した `.uasset` の関数バイトコードを読めるテキストにする（UAssetAPI 流用）。
  `dotnet tools/KismetDump/bin/KismetDump.dll research/extracted research/kismet VER_UE5_5 "E:/SN2ModKit/Automation/Subnautica2-131439.usmap"`
  - **usmap が必須**。TS2 専用が無いため Subnautica 2 の usmap（UE5.6 のエンジン共通クラス分）で代用。BP の関数は読めるが、TS2 の C++ クラスのプロパティ（CDO 等）は読めない（Raw 扱い）。
- `research/kview.py FILE FUNCTION [START] [N]`: ダンプの任意オフセットから文を整形表示。
- 出力: `research/kismet/*.kismet.txt`（主人公 171 関数、コントローラ 163 関数、武器 139 関数 ほか）

## 分かったこと
1. **左スティックの移動基準は `NorthCamera`（Rotator 変数）**。主人公 BP のティックで
   - 通常: `Current Camera Rotator = NorthCamera`（前フレームの値は `Last Camera Rotator`）
   - トレーラーカメラ（`IsTrailerCameraActive?` = T キー）時のみ: 主人公の `FollowCamera` の向きを使う
   - `Last` と `Current` のヨー差が 15° を超えると、スティックを倒している間は旧基準を保持する（レトロ式の「カメラ切替後も走る向きを維持」）。差が小さい間は `RLerp` で追従。
   - 移動は `AddMovementInput(Target Movement Direction, …)`（Yaw は `Current Camera Rotator` から）。`TankMode`/`DigitalMovement`（十字キー）は別系統。
   → **TPS 化の方針: 新カメラのヨーを毎フレーム `NorthCamera`（必要なら `Current/Last Camera Rotator`）に書く**。主人公 `ReceiveTick` の直前（pre フック）に書けば、C++ 側の更新を上書きできる。15° 超の急回転でも旧基準保持が発動しないよう、Last/Current も同値にする案を検討。
2. **`NorthCamera` を BP で書くのは `BP_RailCamera` だけ**（カメラのヨー＝アクター回転を主人公へ）。固定カメラ（`BP_CustomCamera`）側の書き込みは BP に無く、C++（`TormentedSouls2Character` など）が行っていると推測。**実機で `NorthCamera` が値を持つか／毎フレーム更新か要確認（F10 トレース）**。
3. **ビューターゲット切替**: BP 側で `SetViewTargetWithBlend` を呼ぶのは `BP_TS2GameInstance`（`CurrentBPRailCamera.SelfCamera`、ブレンド 0.1 秒）と `BP_PointOfInterest`（POI 演出）のみ。固定カメラの切替は C++ 側（BP から見えない）。セーブには `cameraID`（レールカメラの GUID）が入る。
4. `BP_CustomCamera` は `CineCameraComponent` 1 個 ＋ `FOV` 変数（コンストラクションスクリプトで `SetFieldOfView`）。ロジック無し。
5. 構え/ロックオン関連の主人公関数: `AimCurrentWeapon`, `ReleaseAimCurrentWeapon`, `DetectTargetsToLook`, `GetClosestTarget(ToLook)`, `ChangeCurrentTarget`, `RotateToTarget`, `GetForwardBackwardsDirection`（視野角判定）。カメラ側は対象と構え状態を読むだけで足りる見込み。

## 未解決（実機または C++ 解析が必要）
- 固定カメラへの切替を行う C++ の場所（`PlayerController::SetViewTarget` 系を実機フックで確認するのが最短）
- 通常ゲームプレイ中の判定信号（コントローラの `SwitchMapTo*` で IMC を切替。現在の IMC を読む方法）
- 右スティック既存用途（`IA_InGame_Shortcut_Stick`）との競合

---
# 静的解析（exe の PE を直接読む。Ghidra 全体解析はまだ未実施）

## ツール（読み取りのみ）
- `research/pe_reflect.py <exe> <名前…>`: C 文字列を探し、UE の UECodeGen パラメータ表（プロパティ/関数定義）への参照を表示。
- `research/find_disp.py <exe> <disp16進> [窓] [rot]`: `.text` で指定オフセットのメモリ操作を列挙。→ **クラス文脈が無いとコンストラクタのゼロ初期化に埋もれてノイズが多すぎる**（`+0x688` で 471 件）。逆アセンブラ（Ghidra）での関数単位の解析が必要。

## 分かったこと
1. `NorthCamera` は **C++ クラスのネイティブ UPROPERTY**（`TormentedSouls2Character` 側）。型は Rotator（struct）、**クラス内オフセット `0x688`**（パラメータ表 VA `0x147e0deb0`、`PropertyFlags=0x10000000020005`）。BP 側は C++ の値を読んでいるだけで、**書き込みは C++**（`BP_RailCamera` の BP 書き込みを除く）。
2. C++ キャラクタークラスのプロパティ一覧（宣言順）:
   `CameraBoom`, `FollowCamera`, `GrabCapsule`, `TankMode`, `WalkVelocity`, `RunVelocity`, `MaxRunVelocity`, `RotationVelocity`, `IsRunningTankMode`, **`NorthCamera`, `AutoNorth`, `ActualAngle`, `MarginAngle`**, `WalkPercent`, `RunPercent`, `lastMoveForwardValue/RightValue`, **`bIsEnteringRoom`**, `bIsAnalogMovement`, …, `isAiming`, `aimAux`, `TargetAssigned`, `viewAngle`, `TargetToWatch(s)`, `canLookToTarget`, `CurrentEnemy/Enemies`, `isInputDisabled`, `RightAxisVertical/Horizontal`, `MovingR/L`, `isTurningR/L`, **`RAfterCameraChange`**, `isDpad`, `stickX/Y`, `lastStickX/Y`, `dpadX/Y`, **`ChangeNorth`**, `WeaponSystemComponent` ほか。
   - **`CameraBoom`（スプリングアーム）と `FollowCamera` は C++ 側のメンバー**（UE の TPS テンプレート由来）。固定カメラ運用では通常使われず、トレーラーカメラ（T キー）時だけ `FollowCamera` を使う（BP の解析結果）。
   → **TPS カメラの有力案: 主人公自身の `CameraBoom` + `FollowCamera` を使う**（壁との衝突・カメララグがスプリングアームで得られる）。要実機確認: 各コンポーネントの既定値・`bUsePawnControlRotation`・Activate 状態（F8 スナップショットで取得）。
3. `AutoNorth` / `ActualAngle` / `MarginAngle` / `bIsEnteringRoom` / `RAfterCameraChange` / `ChangeNorth` は、固定カメラ切替時に基準向きを保つ C++ ロジックの変数と推測。TPS 化では `NorthCamera` を毎フレーム上書きして無効化する前提。

## 未解決（実機プローブが最短）
- 固定カメラ切替の C++ 関数の特定（Ghidra で `NorthCamera` オフセット `0x688` の書き込みを持つ `TormentedSouls2Character` のメンバ関数を探す。永続プロジェクトに取り込み、関数単位でデコンパイルする必要あり）

---
# Ghidra 静的解析（2026-11-06）

## 環境
- 永続プロジェクト `research/ghidra/TS2`（exe を `-noanalysis` で取り込み済み、`import.log` が `exit=0`）。
- `tools/ghidra/ghidra-headless.cmd`（JDK21/Ghidra 12.1.4 を呼ぶラッパー）、`tools/ghidra/decompile.cmd <出力ファイル> <VA…>`（指定 VA で関数を作成してデコンパイル。スクリプト `tools/ghidra/scripts/DecompileAt.java`）。出力例: `research/ghidra/dec1.c`、`dec2.c`。
- `research/char_funcs.py <exe> [フィールド,…] [最大サイズ] [必須フィールド]`: C++ キャラクターの UPROPERTY オフセット（UECodeGen の `q6 = ArrayDim(下位16bit) | Offset(次の16bit)<<16`）と、`.pdata` で割り出した関数ごとのフィールド参照を出す。
- `research/nativetab.py <exe> <VA…>`: ネイティブ関数表（`{名前, thunk}`）を列挙。

## C++ キャラクターのオフセット（確定）
`CameraBoom 0x658` / `FollowCamera 0x660` / **`NorthCamera 0x688`** / `ActualAngle 0x6a4` / `MarginAngle 0x6a8` / `TargetToWatch 0x7d0` / `CurrentEnemy 0x868` / `RightAxisVertical 0x898` / `RightAxisHorizontal 0x89c` / `RAfterCameraChange 0x8d8` / `stickX 0x904` / `stickY 0x908` / `WeaponSystemComponent 0x930`

## 結論（NorthCamera を書く C++ 関数は未特定）
- `disp32` を `.text` から拾う方式では、**別クラスのコンストラクタ／コピー（同じ +0x688 付近のゼロ初期化）が大量に混ざり**、移動・ティック系の関数に絞れなかった。上位候補をデコンパイルした結果（`dec1.c`/`dec2.c`）は全てコンストラクタ/コピー系（`param_1[0xd1] = 0` など）。
- `SetShorcutNorth` 等は「ショートカットホイール（中央/東/西/南/北）」の関数で、カメラとは無関係。
- 特定するには、キャラクタークラスの vtable（`Tick`/`PostInitializeComponents` 等の override）から辿るか、実機でフックする必要がある。**実装上は不要**: TPS 化は pre-tick で `NorthCamera` を毎フレーム上書きする方針で、書き込み元が C++ の別関数でも、**同じ tick の後でカメラ基準として読まれる前に上書きできるか**は実機のF10トレースで確認する（`NorthCamera` が BP の `Current Camera Rotator` に取り込まれる前に書く）。
- 次の確認はすべて実機（TS2Probe の F8/F9/F10 とログ）。

---
# 実機プローブ 1 回目の結果（2026-11-06 16:20〜16:23、墓地オフィス）

## 分かったこと（確定）
- **UE4SS は TS2 で起動し、Lua MOD も動作**（クラッシュなし）。`PlayerController:SetViewTargetWithBlend` の RegisterHook は成功。`PlayerController:SetViewTarget` / `PlayerCameraManager:SetViewTarget` は UFunction として存在しない（フック不可）。
- **固定カメラは `BP_CustomCamera` ではなく、レベルに置かれた素の `/Script/Engine.CameraActor`**（例: `Cementery_office:PersistentLevel.CameraActor_0/1/4/5`）。切替は **`TormentedSouls2PlayerController_C` が `SetViewTargetWithBlend(CameraActor_x, 0.0)` を呼ぶ**（ブレンド 0 秒）。→ pre/post フックで差し替え・TPS 化の調停が可能。`BP_CustomCamera_C` のインスタンスは 0 個。
- 主人公は `BP_CarolineNew_C`（`Possess` フックで確認）。ViewTarget は Possess 直後だけ主人公、その後すぐ固定 `CameraActor` に切替わる。
- `BP_RailCamera_C` の C++ 親は `/Script/TormentedSouls2.RailCamera`、武器は `WeaponSystemComponent`、`Weapon`（C++）。
- 入力: **右スティックは `GetInputAnalogKeyState(Gamepad_RightX/Y)` で読める**（-1〜1）。左スティックも同様。マウスは同 API で 0.0（動かしていなければ正常だが要再確認）。`GetInputMouseDelta` は out パラメータにテーブルが必要（プローブを修正済み）。
- 構え中のスナップショット（`snapshot-162211`）では武器が `BP_Crowbar_Weapon_C` に変わっていた。敵（`BP_BaseEnemy_C`）は 0 体の部屋だった。

## プローブの不具合（修正済み、再取得が必要）
- `pc:GetPawn()` は UFunction ではないため nil → **主人公の変数が全て `?`**。`K2_GetPawn()` → `.Pawn` → `FindFirstOf("BP_CarolineNew_C")` に変更。
- `rot()` が `?`（Rotator の読み取り失敗）。原因ログを 1 回だけ出すようにした。
- スナップショットで C++ クラス（`/Script/TormentedSouls2.*`）のプロパティ値も出す。主人公の `CameraBoom`/`FollowCamera` の既定値（腕の長さ、`bUsePawnControlRotation` 等）、`GetControlRotation` も出す。
- `Install-TS2TPS.ps1 -Mods TS2Probe -SkipUE4SS` で再導入済み（16:25）。

## 次の再取得
通常の部屋で F8、歩きながら視点が切り替わる境目をまたいで F10、F9（マウスと右スティック）、敵のいる場所で武器を構えて F8 と F10。

---
# 実機プローブ 3 回目（2026-11-06 16:48〜16:51）— Phase 0 結論

生ログ抜粋: `research/trace-run3.txt`（320 サンプル、墓地オフィス〜Cementery_A/A2）。

## 確定した事実
1. **移動基準の仕組み**: `NorthCamera` は **現在の ViewTarget（固定 CameraActor）の回転（Pitch/Yaw/Roll 全部）と、カメラ切替の瞬間に一致**（320 サンプル中 301 で `Current/Last/NorthCamera` がカメラ回転と完全一致、不一致の 19 サンプルは切替後 ~1.3 秒の補間中）。切替後は `Current Camera Rotator` が `NorthCamera` へ約 1.3 秒かけて補間し、`Last` はそれに少し遅れて追従する（BP の RLerp、旧基準保持の挙動と一致）。
   → **TPS では毎フレーム `NorthCamera` / `Current Camera Rotator` / `Last Camera Rotator` に新カメラの回転を書く**（補間を無効化）。`NorthCamera` が切替時 1 回の書き込みか毎フレームかは未確認だが、どちらでも pre-tick 上書きで対応可能（書き込み可否は Phase 1 で最初に検証）。
2. **固定カメラ = レベル上の素の `CameraActor`**。切替は `TormentedSouls2PlayerController_C` が `SetViewTargetWithBlend(CameraActor, 0.0)` を呼ぶ（部屋の境目で多数確認、Cementery_office / A / A2 / D）。`SetViewTargetWithBlend` の RegisterHook は動作 → 切替の検知・差し替え・調停に使える。
3. **主人公自身のカメラ**: `CameraBoom`（SpringArm、`TargetArmLength=300`、`bUsePawnControlRotation=true`、衝突判定 OFF、ラグ OFF）＋ `FollowCamera`（FOV 90、`bUsePawnControlRotation=false`、Active=true）。通常は ViewTarget が固定カメラなので使われないが、Possess 直後は ViewTarget=主人公になり、このカメラで映る（確認済み）。`GetControlRotation` は常に (0,0,0)＝既定では誰も使っていない。
   → **TPS カメラ案 B（有力）**: ViewTarget を主人公にし、`PlayerController:SetControlRotation` でマウス/スティックから視点を回す（腕の長さ・オフセット・衝突判定は設定で変更可能）。案 A: 専用 CameraActor を毎フレーム更新。どちらもフックと NorthCamera 上書きは共通。
4. **入力**: マウスは `GetInputAnalogKeyState(MouseX/MouseY)`（呼び出し間の移動量。`GetInputMouseDelta(dx,dy)` は out 用に空テーブルを渡せば動く）、右スティックは `Gamepad_RightX/Y`（-1〜1）、左スティックは `Gamepad_LeftX/Y`。
5. **構え**: `isAiming` が構え中に true になるのを確認（`isWeaponEquipped=true`）。ロックオン対象は C++ の `CurrentEnemy`(0x868)/`TargetToWatch`(0x7d0)/`TargetAssigned`。`CurrentTarget` は BP 側の名前で、この主人公では nil。敵のいる状況での値は未取得。
6. **通常プレイ判定の候補**: `isInputDisabled`（イベント中に true を確認: Cementery_A2 の演出中）、`isAiming`、`TankMode`、`bIsAnalogMovement`。

## Go/No-Go: **Go（Lua 方式で進める）**
- UE4SS が TS2 で動作し、必要な読み書き（ビューターゲット切替フック、主人公の変数、入力）が全て Lua から可能。MinHook DLL は現時点で不要。
## 未確認（Phase 1 で最初に検証）
- `NorthCamera`/`Current`/`Last Camera Rotator` への書き込みが反映されるか（反映されたら左スティックの向きが TPS カメラ基準になる）。
- 案 B で ViewTarget=主人公にしたとき、固定カメラ用の PostProcess（画作り）が失われないか。
- `SetControlRotation` が主人公の向きや移動に副作用を出さないか（`bUseControllerRotationYaw`）。
- 敵がいる場面での `CurrentEnemy`/`TargetToWatch` の値。
- 「プレイ中」判定の確実な信号（ムービー・パズル・QTE・POI 中の値）。F1 画面の日本語フォント。

---
# Phase 1 実装（2026-11-06 16:57 導入、実機未検証）
- `TS2TPSCamera/Scripts/`: `config.lua`（設定の定義と既定値）、`camera_math.lua`（純粋計算）、`store.lua`（設定の保存/読込/検証）、`main.lua`（カメラ本体）。テスト: `tests/run_tests.py`（`pip install lupa` が必要。40 チェック全通過、全 Lua の構文チェック込み）。
- 方式: 主人公の `ReceiveTick`（`/Game/Characters/BP_TormentedSoulCharacter.BP_TormentedSoulCharacter_C:ReceiveTick`）の pre-hook で毎フレーム、(1) 固定 `CameraActor` への切替を主人公自身へ差し替え（`SetViewTargetWithBlend` の pre-hook で引数を書き換え＋ティックでも保険）、(2) マウス/右スティックで `ControlRotation` を更新（主人公の `CameraBoom` が追従）、(3) `NorthCamera` と `Current/Last Camera Rotator` に同じヨーを書き込み。
- 手放す条件: ViewTarget が素の `CameraActor` 以外（シネマティック、パズル、POI 等）／`isInputDisabled` が 0.5 秒以上続く → 元の固定カメラに戻す。一時停止中は何もしない。
- デバッグキー（F1 設定画面ができるまで）: F2 オン/オフ、F3/F4 距離 ∓、F5/F6 高さ ∓、F7 肩の左右反転。ログは `[TS2TPS]` 接頭辞。
- 実機で見るログ: `basis write check`（NorthCamera 書き込みが反映されたか）、`basisRewrittenByGame`（ゲームが毎フレーム上書きするか）、`ENGAGED/DISENGAGED` と理由、`originals:`（主人公/ブームの元設定）。

# Phase 1〜4 で実機確認できたこと（2026-11-06）
Phase 1 の「実機未検証」は解消済み。以下はいずれもユーザーが実機で動作確認した内容。

## カメラ・入力
- `FRotator` は Lua から読むとき `pitch` が小文字になる（`Pitch` ではない）。camera.lua / main.lua は両方を試す。
- 右スティックの既存用途（`IA_InGame_Shortcut_Stick`）は、武器ショートカットを pawn の `AxisHorizontal/AxisVertical` に書く。
  数字キー（One..Four / Two..Five）も同じ IA に割り当て。TPS では右スティックをカメラ専用にするため
  この 2 つの書込みを native フックで遮断し、数字キー押下中（0.4 秒窓）だけ通す。
  十字キーでの武器切替は、十字キー入力から同じ値を注入して再現している。
- 左スティック `IA_Move_Stick` → pawn の `SetStickXValue/YValue`（カメラ基準・アナログ）。
  十字キーと WASD は `IA_Move_DPAD` → pawn の `dpadX/dpadY`（タンク操作）。
  WASD を左スティック同様にするには、WASD を正規化して `SetStickX/YValue` に入れ、dpad を空にする。
- タンク移動の実体は `Pawn:AddMovementInput` と `Actor:K2_AddActorWorldRotation`（native）。
  TPS 中に十字キーのみ押されているときは、この 2 つを native フックで無効化（scale=0、回転 delta=0）して移動を止める。
  BP の post-hook はほぼ発火しないため、BP 側で dpadX/Y を 0 にしても効かなかった。
- 歩行モーションは AnimBP（`ABP_CarolineCharacter`）が pawn の `MovingF/B/R/L`・`TankMode` 等を読んで決める。
  `CalculateForwardDirection` / `CalculateTurnDirection` の pre-hook でこれらを落とすと止まる。
- 固定カメラ状態（TPS OFF・ムービー・パズル等）では全て元の挙動。`disengage` で WASD 注入を解除する。

## UE4SS 仕様
- BP 関数フックは、そのクラスがロードされるまで登録できない（"no UFunction with the specified name"）。
  → 1 秒ごとのリトライ登録（`hook_when_loaded`）。native 関数のフックは起動直後から可能。
- `EnhancedInputLocalPlayerSubsystem:GetPlayerInput` は Lua から呼べない。
  入力アクション単位の停止は断念。メニュー・アイテム画面の抑止は `pc:DisableInput` + `pawn:DisableInput` で足りた。
- ゲームの停止は `SetGlobalTimeDilation(0.0001)` + DisableInput。キーは `GetInputAnalogKeyState` をポーリング。

## UI・言語・フォント
- 言語判定: GameInstance の `GetTextByID("UI_L_Language")` が「言語」なら日本語、"Language" なら英語。
  言語番号 9 = 日本語（フォールバック、`japanese_value`）。
- ゲームのフォントには日本語グリフが無く、かな・漢字はエンジンの `DroidSansFallback` が補う。
  ラテン文字・数字まで同じ見た目にするため、`StaticConstructObject`（Roboto をテンプレート）で
  全 typeface の FontFaceAsset を DroidSansFallback に差し替えた Font をその場で作る（ui.lua `build_unified_font`）。
- 設定画面の表示中は、アイテム画面・メニュー画面が出ないよう入力を止める。

## 後から分かったこと（2026-11-07）
- 目のマーク（POI）: 調べている間は `bIsInsideInteraction` だけが立ち、ゲームはカメラを動かさない場合がある。別カメラ（`BP_PointOfInterest`）へ切り替える場合もある。
- 終了時、ゲームは固定カメラ（CameraActor）を `SetViewTargetWithBlend` で返すが、`ViewTarget.Target` が変わるのはブレンド終了後（約 1 秒）。フラグはさらに約 1 秒残る。
- はしご: `BPC_ClimbSystem`（`CurrentLadder`、`IsClimbingLadder()` = CurrentLadder が有効）。上り下りは演出で、全体で `isInputDisabled` が真。
- アイテム調査画面: `IMC_Inventory` の `IA_Inv_RotationStick`（右スティック）→ コントローラ → pawn の `AxisHorizontal/AxisVertical`。
- ロックオン: 構えた瞬間（標的が決まる/切り替わる）だけ敵へ回し、向いたら自由視点に戻す。
- 台車を押す・引く: pawn の `IsPushingObject` は変化しない。`BP_PushSystemComponent`（`pawn.PushSystemComponent`）の `CurrentPushable` が有効なら押している。押している間は `bIsInsideInteraction` も立つが、カメラは動かさないので TPS のまま自由に見回せる。
- 懐中電灯: `IA_InGame_CenterShortcut`（F / `Gamepad_RightThumbstick`）→ pawn の `BPC_ShoulderLampSystem:ToggleLamp`（複雑な ubergraph で二重呼び出し不可）。`IA_InGame_OpenDebugMenu` は P / `Gamepad_LeftThumbstick`。パッドの割り当てだけを `InputMappingContext` の Mappings と `EnhancedPlayerInput.EnhancedActionMappings` で書き換える（RS→LS、デバッグメニューは無効）。書き換え自体はログ（`key remap` / `pad button remap`）で確認できたが、LS で懐中電灯が実際に点くかは実機で未確認。マッピングの一覧は scratchpad の `imcdump` ツールで出した。
- セーブのロード: コントローラとキャラが作り直される（オブジェクト名は同じ、アドレスが違う）。新キャラの `CameraBoom` 等はゲームの既定値なので、TPS 状態を引き継ぐと高さ・肩・FOV が入らず視点が下がる。キャラ／コントローラのアドレスが変わったらカメラ設定を再適用し、向きを背後・既定の上下角に戻す。直後の約 3.5 秒は、キャラが保存位置へ移動・回転する間カメラを背後に合わせ続ける（視点入力か歩行で解除）。
- UE4SS: このプロジェクトの Lua は `LoopInGameThreadWithDelay`（遅延アクション API）を使う。公式のタグ版 v3.0.0 / v3.0.1 に無い可能性があり、experimental ビルドで開発・確認した（`dwmapi.dll` + `ue4ss\` 配置）。

## 未確認・仕様上のずれ
- カメラ位置画面の LB/RB の表記は「LB=手前 / RB=奥」だが、実際の動作は LB=奥 / RB=手前（ユーザー指定で表記のみ変更）。
- クリーンアップ（診断コード削除）後のビルドで、ユーザーは WASD・数字キー・固定カメラ時の元操作を確認済み。
