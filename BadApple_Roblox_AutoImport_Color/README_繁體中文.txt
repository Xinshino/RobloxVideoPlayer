Bad Apple!! Roblox 自動匯入工具
================================

目標：
- 不用把每個影格逐一複製到 Roblox Studio。
- Python 先把影片轉成黑白影格資料。
- Rojo 將資料夾同步到 Roblox Studio。
- 播放器用音訊 Asset ID：93447162676184。

注意：
1. 這個工具需要你有一份本機影片檔（畫面來源），不只是 YouTube 網址。
2. 音訊能否播放取決於 Roblox 音訊資產權限。
3. 這是可測試的原型，第一次請先用短影片測試。
4. 32×18、10 FPS。每個影格是 576 個 0/1 字元，黑色=0、白色=1。

【步驟一：安裝 Python 套件】
在這個資料夾開啟 CMD：
    py -m pip install opencv-python numpy

【步驟二：產生影格資料】
把影片放進此資料夾，檔名改成 bad_apple.mp4。
執行：
    py convert.py

完成後會建立 src/ReplicatedStorage/BadApple/FrameChunks/FrameChunk_001.module.lua ...
影片轉換完成後，資料會自動切成每 60 幀一個 ModuleScript 檔案。

【步驟三：安裝 Rojo】
1. 安裝 Rojo（建議使用官方 Rojo 文件提供的安裝方式）。
2. 在 Roblox Studio 安裝 Rojo 插件。
3. 開啟 Roblox Studio，建立或開啟你的體驗。
4. 在這個資料夾開啟 CMD，執行：
       rojo serve default.project.json
5. 在 Studio 的 Rojo 插件中連線到本機伺服器（通常是 127.0.0.1:34872）。
6. Rojo 會自動把 src 裡的腳本和影格資料同步進 Studio。

這樣就不用一個一個複製貼上了。Rojo 連線只在你的電腦本機運作。

【步驟四：測試】
- 發布/測試體驗前，先確認音訊可以在該體驗播放。
- 執行後會在 Workspace 建立像素牆。
- 玩家加入後，客戶端會依伺服器時間同步畫面與音訊。
- 若影片有不同長度，播放器會依實際轉出的影格數結束。

【重要】
這套程式不會從 YouTube 自動下載影片。請使用你有權使用的本機影片檔。
若 Rojo 未安裝成功，先不要回頭逐個貼資料；把錯誤訊息貼給我，我可以幫你排查。
