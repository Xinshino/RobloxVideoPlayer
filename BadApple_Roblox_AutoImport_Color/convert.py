from pathlib import Path
import cv2
import numpy as np
import math
import shutil
import time
import os

ROOT = Path(__file__).resolve().parent
VIDEO = ROOT / "bad_apple.mkv"
SRC = ROOT / "src" / "ReplicatedStorage" / "BadApple"
CHUNKS = SRC / "FrameChunks"
TEMP_CHUNKS = SRC / "FrameChunks_temp"
BACKUP_CHUNKS = SRC / "FrameChunks_backup"

# 輸出設定：必須與 Roblox Client 的 Config 一致
# 來源影片可以是 480x360，不代表輸出也要是 480x360
WIDTH = 192
HEIGHT = 108
FPS = 120

# 資料設定
FRAMES_PER_CHUNK = 60
AUDIO_ID = "93447162676184"


def lua_string(s: str) -> str:
    return '"' + s + '"'


def write_chunk(path: Path, frames: list[str]):
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write("return {\n")
        for frame in frames:
            f.write("    ")
            f.write(lua_string(frame))
            f.write(",\n")
        f.write("}\n")


def format_time(seconds: float) -> str:
    if not math.isfinite(seconds) or seconds < 0:
        return "計算中"

    seconds = int(seconds)
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)

    if hours:
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}"
    return f"{minutes:02d}:{seconds:02d}"


def main():
    if not VIDEO.exists():
        print(f"找不到影片：{VIDEO}")
        print("請把 bad_apple.mkv 放在 convert.py 同一個資料夾。")
        return

    if WIDTH <= 0 or HEIGHT <= 0 or FPS <= 0:
        print("WIDTH、HEIGHT、FPS 必須大於 0。")
        return

    # 先清理上一次留下的暫存資料，不動正式輸出
    for path in (TEMP_CHUNKS, BACKUP_CHUNKS):
        if path.exists():
            shutil.rmtree(path)

    cap = cv2.VideoCapture(str(VIDEO))

    if not cap.isOpened():
        print("影片無法開啟，請確認檔案完整。")
        return

    original_fps = cap.get(cv2.CAP_PROP_FPS)
    source_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    if not math.isfinite(original_fps) or original_fps <= 0:
        cap.release()
        print("無法取得影片 FPS。")
        return

    if source_count <= 0:
        cap.release()
        print("無法取得影片影格數。")
        return

    duration = source_count / original_fps
    target_count = max(1, math.ceil(duration * FPS - 1e-8))

    print("=" * 48)
    print(f"來源影片：{VIDEO.name}")
    print(f"來源解析度：{int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))} x "
          f"{int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))}")
    print(f"來源 FPS：{original_fps:.3f}")
    print(f"影片長度：約 {format_time(duration)}")
    print(f"輸出解析度：{WIDTH} x {HEIGHT}")
    print(f"輸出 FPS：{FPS}")
    print(f"預計影格數：{target_count:,}")
    print(f"每個 Chunk：{FRAMES_PER_CHUNK} 幀")
    print("=" * 48)
    print("開始轉換。進度會定期更新，請稍候。", flush=True)

    SRC.mkdir(parents=True, exist_ok=True)
    TEMP_CHUNKS.mkdir(parents=True, exist_ok=True)

    # 暫存輸出：轉換成功後才替換正式資料
    chunk_frames = []
    chunk_index = 0
    output_count = 0
    source_index = 0
    next_sample_time = 0.0

    started = time.perf_counter()
    last_report = started
    last_report_count = 0

    # 只需將每個來源影格縮放、二值化一次；
    # NumPy 避免逐像素執行 Python 迴圈。
    try:
        while output_count < target_count:
            ok, frame = cap.read()

            if not ok:
                break

            timestamp = source_index / original_fps

            # 依時間取樣；來源 FPS 低於輸出 FPS 時會重複影格
            while (
                next_sample_time <= timestamp + 1e-8
                and output_count < target_count
            ):
                small = cv2.resize(
                    frame,
                    (WIDTH, HEIGHT),
                    interpolation=cv2.INTER_AREA
                )

                gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)

                # 直接產生 ASCII '0'/'1'，取代逐像素字串迴圈
                binary = np.where(gray >= 128, 49, 48).astype(np.uint8)
                bits = binary.tobytes().decode("ascii")

                chunk_frames.append(bits)
                output_count += 1
                next_sample_time += 1.0 / FPS

                if len(chunk_frames) >= FRAMES_PER_CHUNK:
                    chunk_index += 1
                    chunk_path = (
                        TEMP_CHUNKS /
                        f"FrameChunk_{chunk_index:03d}.lua"
                    )
                    write_chunk(chunk_path, chunk_frames)
                    chunk_frames.clear()

            source_index += 1

            now = time.perf_counter()
            if now - last_report >= 2.0:
                elapsed = now - started
                progress = output_count / target_count
                speed = output_count / elapsed if elapsed > 0 else 0
                remaining = (
                    (target_count - output_count) / speed
                    if speed > 0 else float("inf")
                )

                print(
                    f"\r進度：{progress * 100:6.2f}% | "
                    f"{output_count:,}/{target_count:,} 幀 | "
                    f"速度：{(output_count - last_report_count) / (now - last_report):.1f} 幀/秒 | "
                    f"已耗時：{format_time(elapsed)} | "
                    f"剩餘：約 {format_time(remaining)}",
                    end="",
                    flush=True
                )

                last_report = now
                last_report_count = output_count

        # 寫入最後一個不滿 60 幀的 Chunk
        if chunk_frames:
            chunk_index += 1
            write_chunk(
                TEMP_CHUNKS / f"FrameChunk_{chunk_index:03d}.lua",
                chunk_frames
            )
            chunk_frames.clear()

    except KeyboardInterrupt:
        print("\n使用者中止轉換。原本正式資料保留。")
        return
    except Exception as exc:
        print(f"\n轉換失敗：{type(exc).__name__}: {exc}")
        print("原本正式資料保留。")
        return
    finally:
        cap.release()

    if output_count == 0:
        print("\n沒有讀取到影格，轉換失敗。")
        return

    elapsed = time.perf_counter() - started

    print()
    print(f"影格處理完成：{output_count:,}/{target_count:,}")

    if output_count != target_count:
        print("警告：實際影格數與預計值不同，可能是影片提前結束。")

    # Config 使用實際輸出影格數
    config_text = (
        "return {\n"
        f"    Width = {WIDTH},\n"
        f"    Height = {HEIGHT},\n"
        f"    FPS = {FPS},\n"
        f"    FrameCount = {output_count},\n"
        f'    SoundId = "rbxassetid://{AUDIO_ID}",\n'
        f"    FramesPerChunk = {FRAMES_PER_CHUNK},\n"
        "}\n"
    )

    temp_config = SRC / "Config.module.lua.tmp"
    config_path = SRC / "Config.module.lua"

    try:
        temp_config.write_text(config_text, encoding="utf-8")

        # 先保留舊資料，再將新資料移入正式位置
        if CHUNKS.exists():
            CHUNKS.rename(BACKUP_CHUNKS)

        try:
            TEMP_CHUNKS.rename(CHUNKS)
            os.replace(temp_config, config_path)
        except Exception:
            # 若替換失敗，盡可能還原舊資料
            if CHUNKS.exists():
                shutil.rmtree(CHUNKS)
            if BACKUP_CHUNKS.exists():
                BACKUP_CHUNKS.rename(CHUNKS)
            raise

        # 新資料成功就位後才刪除備份
        if BACKUP_CHUNKS.exists():
            shutil.rmtree(BACKUP_CHUNKS)

    except Exception as exc:
        print(f"\n更新輸出資料失敗：{exc}")
        print("請保留備份資料夾，不要手動刪除。")
        return

    print()
    print("=" * 48)
    print("轉換完成！")
    print(f"實際影格數：{output_count:,}")
    print(f"影格模組數：{chunk_index}")
    print(f"解析度：{WIDTH} x {HEIGHT}")
    print(f"FPS：{FPS}")
    print(f"總耗時：{format_time(elapsed)}")
    print(f"資料位置：{SRC}")
    print("=" * 48)
    print("請確認 Rojo 已同步到 Roblox Studio，再進行測試。")


if __name__ == "__main__":
    main()