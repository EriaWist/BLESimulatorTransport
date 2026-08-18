# BluetoothMock Demo

這個 SwiftUI App 可以在兩台 iOS Simulator 分別扮演 Peripheral 與 Central，完整操作 `BluetoothMock` 的 scan、connect、read、write、subscribe、notify 與 MTU 超限拒絕。

## 啟動

1. 用 Xcode 開啟根目錄的 `BluetoothMockDemo.xcodeproj`。
2. 選擇第一台 Simulator 後執行 `BluetoothMockDemo` scheme。
3. 選擇 **Peripheral**，按下「啟動」，等待狀態顯示 `Advertising：127.0.0.1:7799`。
4. 如果要改用第二台 Simulator 執行同一個 scheme，先停止 Xcode debugger，再從第一台 Simulator 的主畫面手動重新開啟 BluetoothMock Demo 並啟動 Peripheral；這樣它不會隨第二次 Run 被 Xcode 終止。
5. 在第二台 Simulator 執行 App，選擇 **Central** 後按下「啟動」。
6. Central 會自動 scan、connect、探索 `FFF0/FFF1`、訂閱 notification 並 read 初始值。

兩端事件紀錄會顯示傳輸方向、時間、資料長度與錯誤。

## 可試操作

- Central 輸入 UTF-8 文字後按 **Write**，Peripheral 會顯示收到的內容。
- Peripheral 輸入文字後按 **送出 Notification**，Central 會收到更新。
- Central 按 **Read** 取得 Peripheral 目前的 characteristic value。
- 任一端按 **測試超過 MTU 的傳輸**，應看到 245-byte payload 被拒絕；本 Demo 使用 ATT MTU 247，因此單次 GATT payload 上限為 244 bytes。

## UI 錯誤測試

畫面中的 **BLE 限制** 區塊可直接按下以下測試；正確拒絕非法操作時，事件紀錄會顯示綠色「通過」：

- 超過協商 ATT MTU 的 Write／Notification。
- 513-byte attribute value（BLE 上限為 512 bytes）。
- 超過 31 bytes 的 legacy advertising。
- 無效的 Bluetooth UUID。
- Read property 缺少 `.readable` permission（需先啟動 Peripheral）。
- characteristic 沒有 notify／indicate property 卻嘗試送出 Notification。

**連線品質與斷線測試** 區塊提供三個可點擊情境：

- **正常連線並重啟**：移除 fault injection。
- **高延遲＋逐 byte 拆包並重啟**：每個 wire frame 延遲 80 ms，並拆成 1-byte TCP send，測試 TCP 嚴重拆包時 GATT 是否仍正常。
- **Read 傳輸途中斷線並重啟**：限 Central，送出 Read frame 後立刻切斷 TCP；事件紀錄會驗證 pending callback 與 `didDisconnectPeripheral` 都收到錯誤。

若要模擬雙向劣質連線，可先在 Peripheral 點擊劣質連線重啟，再到 Central 點擊同一情境。

## Project 結構

Demo project 的 `BluetoothMock` framework target 直接引用根目錄 `Sources/BluetoothMock` 的同一份檔案，沒有複製套件程式碼。這是為了讓位於 package 根目錄內的試用 project 可直接開啟編譯；正式 App 請依根目錄 README 使用 Swift Package Manager product。
