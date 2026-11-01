
from pathlib import Path
import base64
import json
import math
import os
import shutil
import time
import traceback

import cv2
import numpy as np


# ============================================================
# 基本設定
# ============================================================

ROOT = Path(__file__).resolve().parent

WIDTH = 256
HEIGHT = 144

FPS_OVERRIDE = None

FRAMES_PER_CHUNK = 30
PALETTE_SIZE = 256

# 調色盤取樣總上限
PALETTE_SAMPLE_LIMIT = 1_000_000

# 音訊資產 ID
AUDIO_ID = "140552644214983"

# RGB 查找表的量化等級
COLOR_LEVELS = 32

# 是否保留原始比例，不足的地方使用黑色補齊
FIT_WITH_LETTERBOX = True

PROGRESS_INTERVAL = 1.0

# 調色盤取樣影格上限
PALETTE_SAMPLE_FRAMES = 30

VIDEO_EXTENSIONS = {
    ".mp4", ".mkv", ".avi", ".mov", ".webm",
    ".m4v", ".mpeg", ".mpg", ".wmv", ".flv",
}


# ============================================================
# 選擇影片
# ============================================================

def find_videos():
    return sorted(
        [
            p for p in ROOT.iterdir()
            if p.is_file()
            and p.suffix.lower() in VIDEO_EXTENSIONS
        ],
        key=lambda p: p.name.lower(),
    )


def select_video():
    videos = find_videos()

    if not videos:
        raise FileNotFoundError(
            f"找不到影片！\n"
            f"請把影片放在這個位置：\n{ROOT}"
        )

    if len(videos) == 1:
        print(f"自動選擇影片：{videos[0].name}")
        return videos[0]

    print("\n找到以下影片：")

    for i, video in enumerate(videos, 1):
        print(f"  {i}. {video.name}")

    while True:
        try:
            choice = int(input("\n輸入影片編號："))

            if 1 <= choice <= len(videos):
                return videos[choice - 1]

        except ValueError:
            pass

        print("輸入錯誤，請重新輸入。")


# ============================================================
# 路徑設定
# ============================================================

def setup_output_paths(video):
    output = ROOT / "src" / "ReplicatedStorage" / video.stem
    chunks = output / "FrameChunks"

    output.mkdir(parents=True, exist_ok=True)

    print(f"\n影片來源：{video}")
    print(f"輸出位置：{output.resolve()}\n")

    return output, chunks


# ============================================================
# 畫面處理
# ============================================================

def resize_frame(frame):
    if not FIT_WITH_LETTERBOX:
        return cv2.resize(
            frame,
            (WIDTH, HEIGHT),
            interpolation=cv2.INTER_AREA,
        )

    source_h, source_w = frame.shape[:2]

    scale = min(
        WIDTH / source_w,
        HEIGHT / source_h,
    )

    new_w = max(1, round(source_w * scale))
    new_h = max(1, round(source_h * scale))

    resized = cv2.resize(
        frame,
        (new_w, new_h),
        interpolation=cv2.INTER_AREA,
    )

    canvas = np.zeros(
        (HEIGHT, WIDTH, 3),
        dtype=np.uint8,
    )

    x = (WIDTH - new_w) // 2
    y = (HEIGHT - new_h) // 2

    canvas[y:y + new_h, x:x + new_w] = resized

    return canvas


# ============================================================
# 建立調色盤
# ============================================================

def build_palette(video):
    cap = cv2.VideoCapture(str(video))

    if not cap.isOpened():
        raise RuntimeError(f"無法開啟影片：{video}")

    frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    if frame_count <= 0:
        cap.release()
        raise RuntimeError("影片沒有可讀取的畫面。")

    sample_frame_count = min(
        frame_count,
        PALETTE_SAMPLE_FRAMES,
    )

    positions = np.linspace(
        0,
        frame_count - 1,
        sample_frame_count,
        dtype=np.int32,
    )

    pixels_per_frame = max(
        1,
        PALETTE_SAMPLE_LIMIT // sample_frame_count,
    )

    samples = []

    print("\n正在分析影片顏色……")
    print(f"影片總影格：{frame_count:,}")
    print(f"調色盤取樣影格：{sample_frame_count}")
    print(f"每張影格最多取樣：{pixels_per_frame:,} 個像素")

    try:
        for sample_index, position in enumerate(positions, 1):
            cap.set(
                cv2.CAP_PROP_POS_FRAMES,
                int(position),
            )

            ok, frame = cap.read()

            if not ok:
                print(f"警告：第 {position} 幀讀取失敗，跳過。")
                continue

            # OpenCV 預設為 BGR，統一轉換成 RGB
            frame = cv2.cvtColor(
                resize_frame(frame),
                cv2.COLOR_BGR2RGB,
            )

            pixels = frame.reshape(-1, 3)

            if len(pixels) > pixels_per_frame:
                indices = np.linspace(
                    0,
                    len(pixels) - 1,
                    pixels_per_frame,
                    dtype=np.int32,
                )

                pixels = pixels[indices]

            samples.append(pixels)

            print(
                f"\r調色盤取樣：{sample_index}/{sample_frame_count}",
                end="",
                flush=True,
            )

    finally:
        cap.release()

    print()

    if not samples:
        raise RuntimeError("無法取得影片顏色樣本。")

    pixels = np.concatenate(samples).astype(np.float32)

    if len(pixels) < PALETTE_SIZE:
        repeats = math.ceil(
            PALETTE_SIZE / len(pixels)
        )

        pixels = np.tile(
            pixels,
            (repeats, 1),
        )

    pixels = np.ascontiguousarray(pixels)

    criteria = (
        cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER,
        50,
        0.5,
    )

    cv2.setRNGSeed(42)

    print("正在使用 K-means 建立調色盤……")

    _, _, centers = cv2.kmeans(
        pixels,
        PALETTE_SIZE,
        None,
        criteria,
        3,
        cv2.KMEANS_PP_CENTERS,
    )

    palette = np.clip(
        np.round(centers),
        0,
        255,
    ).astype(np.uint8)

    color_count = int(np.count_nonzero(
        (palette[:, 0] != palette[:, 1]) |
        (palette[:, 1] != palette[:, 2])
    ))

    gray_count = PALETTE_SIZE - color_count

    print("\n========== 調色盤診斷 ==========")
    print(f"調色盤總數：{len(palette)}")
    print(f"彩色項目：{color_count}")
    print(f"灰階項目：{gray_count}")
    print("前 12 個顏色（RGB）：")

    for i, color in enumerate(palette[:12]):
        r, g, b = map(int, color)
        print(f"  [{i}] RGB({r}, {g}, {b})")

    if color_count == 0:
        print("警告：調色盤全部為灰階！")
    elif color_count < 10:
        print("警告：彩色項目很少，請檢查來源影片色彩。")
    else:
        print("調色盤包含彩色項目。")

    print("================================\n")

    return palette


# ============================================================
# 建立 RGB 查找表
# ============================================================

def build_rgb_lookup(palette):
    print("正在建立 RGB 查找表……")

    values = np.linspace(
        0,
        255,
        COLOR_LEVELS,
        dtype=np.float32,
    )

    r, g, b = np.meshgrid(
        values,
        values,
        values,
        indexing="ij",
    )

    grid = np.stack(
        [r, g, b],
        axis=-1,
    ).reshape(-1, 3)

    palette_float = palette.astype(np.float32)

    lookup = np.empty(
        len(grid),
        dtype=np.uint8,
    )

    # 分批計算，避免一次建立過大的距離矩陣
    for start in range(0, len(grid), 2048):
        end = min(
            start + 2048,
            len(grid),
        )

        batch = grid[start:end]

        differences = (
            batch[:, None, :]
            - palette_float[None, :, :]
        )

        distances = np.sum(
            differences * differences,
            axis=2,
        )

        lookup[start:end] = np.argmin(
            distances,
            axis=1,
        )

    return lookup.reshape(
        COLOR_LEVELS,
        COLOR_LEVELS,
        COLOR_LEVELS,
    )


# ============================================================
# 編碼影格
# ============================================================

def encode_frame(frame, lookup):
    frame = cv2.cvtColor(
        resize_frame(frame),
        cv2.COLOR_BGR2RGB,
    )

    quantized = (
        frame.astype(np.uint16)
        * (COLOR_LEVELS - 1)
        // 255
    ).astype(np.uint8)

    indices = lookup[
        quantized[:, :, 0],
        quantized[:, :, 1],
        quantized[:, :, 2],
    ]

    return base64.b64encode(
        indices.tobytes()
    ).decode("ascii")


# ============================================================
# 寫入 Lua 檔案
# ============================================================

def write_palette(path, palette):
    lines = [
        "-- Generated by convert.py",
        "return {",
    ]

    for color in palette:
        r, g, b = map(int, color)

        lines.append(
            f"    {{{r}, {g}, {b}}},"
        )

    lines.append("}")

    path.write_text(
        "\n".join(lines) + "\n",
        encoding="utf-8",
    )


def write_config(path, fps, frame_count):
    content = f'''-- Generated by convert.py
return {{
    Width = {WIDTH},
    Height = {HEIGHT},
    FPS = {fps:.6f},
    FrameCount = {frame_count},
    SoundId = "{AUDIO_ID}",
    FramesPerChunk = {FRAMES_PER_CHUNK},
    ColorMode = true,
    PaletteSize = {PALETTE_SIZE},
    FrameEncoding = "Base64PaletteIndex",
}}
'''

    path.write_text(
        content,
        encoding="utf-8",
    )


def write_chunk(path, frames):
    lines = [
        "-- Generated by convert.py",
        "return {",
    ]

    for frame in frames:
        lines.append(f'    "{frame}",')

    lines.append("}")

    path.write_text(
        "\n".join(lines) + "\n",
        encoding="utf-8",
    )


# ============================================================
# 更新 Rojo 專案設定
# ============================================================

def update_rojo_project(video_name):
    project_file = ROOT / "default.project.json"

    if not project_file.exists():
        print(
            "提示：沒有 default.project.json，"
            "跳過 Rojo 設定更新。"
        )
        return

    try:
        project = json.loads(
            project_file.read_text(
                encoding="utf-8-sig",
            )
        )

        tree = project.setdefault("tree", {})
        replicated = tree.setdefault(
            "ReplicatedStorage",
            {},
        )

        folder_path = (
            f"src/ReplicatedStorage/{video_name}"
        )

        existing = replicated.get(video_name)

        if existing is None:
            replicated[video_name] = {
                "$path": folder_path,
            }

        elif existing != {"$path": folder_path}:
            print(
                f"警告：Rojo 設定中已有 {video_name}，"
                "未覆蓋該項目。"
            )
            return

        else:
            print("Rojo 設定已包含此影片。")
            return

        temp = project_file.with_suffix(".json.tmp")

        temp.write_text(
            json.dumps(
                project,
                ensure_ascii=False,
                indent=4,
            ) + "\n",
            encoding="utf-8",
        )

        temp.replace(project_file)

        print("已更新 default.project.json。")

    except Exception as exc:
        print(f"更新 Rojo 設定失敗：{exc}")


# ============================================================
# 來源影片色彩診斷
# ============================================================

def diagnose_source_color(video):
    cap = cv2.VideoCapture(str(video))

    if not cap.isOpened():
        print("警告：無法開啟影片進行色彩診斷。")
        return

    frame_count = int(
        cap.get(cv2.CAP_PROP_FRAME_COUNT)
    )

    if frame_count <= 0:
        cap.release()
        print("警告：影片沒有可讀取的畫面。")
        return

    positions = np.linspace(
        0,
        frame_count - 1,
        min(10, frame_count),
        dtype=np.int32,
    )

    color_pixels = 0
    total_pixels = 0
    max_channel_diff = 0

    print("正在檢查來源影片的色彩……")

    try:
        for position in positions:
            cap.set(
                cv2.CAP_PROP_POS_FRAMES,
                int(position),
            )

            ok, frame = cap.read()

            if not ok:
                continue

            rgb = cv2.cvtColor(
                resize_frame(frame),
                cv2.COLOR_BGR2RGB,
            ).astype(np.int16)

            channel_diff = (
                np.max(rgb, axis=2)
                - np.min(rgb, axis=2)
            )

            color_pixels += int(
                np.count_nonzero(channel_diff > 8)
            )

            total_pixels += int(channel_diff.size)

            if channel_diff.size:
                max_channel_diff = max(
                    max_channel_diff,
                    int(channel_diff.max()),
                )

    finally:
        cap.release()

    print("\n========== 來源影片色彩診斷 ==========")

    if total_pixels:
        percentage = (
            color_pixels / total_pixels * 100
        )

        print(
            f"明顯有色差的像素：{percentage:.2f}%"
        )

        print(
            f"最大 RGB 色差：{max_channel_diff}"
        )

        if color_pixels == 0:
            print(
                "警告：抽樣畫面看起來是灰階，"
                "請確認來源影片。"
            )
        else:
            print("來源影片包含彩色像素。")

    else:
        print("無法取得有效的色彩樣本。")

    print("======================================\n")


# ============================================================
# 主程式
# ============================================================

def main():
    start_time = time.time()

    video = select_video()

    output, chunks_dir = setup_output_paths(video)

    print("正在讀取影片資訊……")

    cap = cv2.VideoCapture(str(video))

    if not cap.isOpened():
        raise RuntimeError(
            f"無法開啟影片：{video}"
        )

    source_fps = cap.get(
        cv2.CAP_PROP_FPS
    )

    source_frame_count = int(
        cap.get(cv2.CAP_PROP_FRAME_COUNT)
    )

    cap.release()

    if source_frame_count <= 0:
        raise RuntimeError(
            "影片沒有可讀取的畫面。"
        )

    fps = (
        FPS_OVERRIDE
        if FPS_OVERRIDE is not None
        else source_fps
    )

    if not fps or fps <= 0:
        raise RuntimeError("影片 FPS 無效。")

    print(f"FPS：{fps:.3f}")
    print(f"預計影格數：{source_frame_count:,}")
    print(f"解析度：{WIDTH} x {HEIGHT}")

    # 先確認來源影片是否本身包含彩色
    diagnose_source_color(video)

    # 建立調色盤
    palette = build_palette(video)

    # 建立 RGB 查找表
    lookup = build_rgb_lookup(palette)

    # ========================================================
    # 建立暫存輸出資料
    # ========================================================

    temp_chunks = output / "FrameChunks_temp"

    if temp_chunks.exists():
        shutil.rmtree(temp_chunks)

    temp_chunks.mkdir(parents=True)

    temp_palette = (
        output / "ColorPalette_temp.module.lua"
    )

    temp_config = (
        output / "Config_temp.module.lua"
    )

    write_palette(
        temp_palette,
        palette,
    )

    cap = cv2.VideoCapture(str(video))

    if not cap.isOpened():
        raise RuntimeError(
            f"無法重新開啟影片：{video}"
        )

    chunk_frames = []
    total_frames = 0
    chunk_index = 1
    last_progress = time.time()

    try:
        while True:
            ok, frame = cap.read()

            if not ok:
                break

            encoded = encode_frame(
                frame,
                lookup,
            )

            chunk_frames.append(encoded)
            total_frames += 1

            if len(chunk_frames) >= FRAMES_PER_CHUNK:
                chunk_path = (
                    temp_chunks
                    / f"FrameChunk_{chunk_index:03d}.module.lua"
                )

                write_chunk(
                    chunk_path,
                    chunk_frames,
                )

                chunk_frames.clear()
                chunk_index += 1

            if (
                time.time() - last_progress
                >= PROGRESS_INTERVAL
            ):
                percent = (
                    total_frames
                    / source_frame_count
                    * 100
                )

                print(
                    f"\r轉換進度："
                    f"{total_frames:,}/"
                    f"{source_frame_count:,} "
                    f"({percent:.1f}%)",
                    end="",
                    flush=True,
                )

                last_progress = time.time()

        if chunk_frames:
            chunk_path = (
                temp_chunks
                / f"FrameChunk_{chunk_index:03d}.module.lua"
            )

            write_chunk(
                chunk_path,
                chunk_frames,
            )

    finally:
        cap.release()

    print()

    if total_frames <= 0:
        raise RuntimeError(
            "沒有成功轉換任何影格。"
        )

    write_config(
        temp_config,
        fps,
        total_frames,
    )

    # ========================================================
    # 驗證暫存資料
    # ========================================================

    expected_chunks = math.ceil(
        total_frames / FRAMES_PER_CHUNK
    )

    actual_chunks = list(
        temp_chunks.glob(
            "FrameChunk_*.module.lua"
        )
    )

    if len(actual_chunks) != expected_chunks:
        raise RuntimeError(
            f"Chunk 數量不符！"
            f"預期 {expected_chunks}，"
            f"實際 {len(actual_chunks)}"
        )

    if (
        not temp_palette.exists()
        or not temp_config.exists()
    ):
        raise RuntimeError(
            "Config 或 ColorPalette 檔案未成功產生。"
        )

    # ========================================================
    # 替換正式資料
    # ========================================================

    backup_chunks = (
        output / "FrameChunks_backup"
    )

    if backup_chunks.exists():
        shutil.rmtree(backup_chunks)

    had_chunks = chunks_dir.exists()

    try:
        if had_chunks:
            chunks_dir.rename(
                backup_chunks
            )

        temp_chunks.rename(
            chunks_dir
        )

        temp_palette.replace(
            output / "ColorPalette.module.lua"
        )

        temp_config.replace(
            output / "Config.module.lua"
        )

        if backup_chunks.exists():
            shutil.rmtree(
                backup_chunks
            )

    except Exception:
        if (
            chunks_dir.exists()
            and backup_chunks.exists()
        ):
            shutil.rmtree(
                chunks_dir
            )

        if backup_chunks.exists():
            backup_chunks.rename(
                chunks_dir
            )

        raise

    # ========================================================
    # 產生轉換報告
    # ========================================================

    report = {
        "video": video.name,
        "output_folder": str(
            output.resolve()
        ),
        "width": WIDTH,
        "height": HEIGHT,
        "fps": fps,
        "frame_count": total_frames,
        "frames_per_chunk": FRAMES_PER_CHUNK,
        "chunk_count": expected_chunks,
        "palette_size": PALETTE_SIZE,
        "frame_encoding": "Base64PaletteIndex",
        "color_mode": True,
        "sound_id": AUDIO_ID,
        "elapsed_seconds": round(
            time.time() - start_time,
            2,
        ),
    }

    (
        output / "convert_report.json"
    ).write_text(
        json.dumps(
            report,
            ensure_ascii=False,
            indent=4,
        ),
        encoding="utf-8",
    )

    update_rojo_project(
        video.stem
    )

    # ========================================================
    # 最後檢查
    # ========================================================

    required_files = [
        output / "Config.module.lua",
        output / "ColorPalette.module.lua",
    ]

    missing = [
        str(path)
        for path in required_files
        if not path.is_file()
    ]

    final_chunks = list(
        chunks_dir.glob(
            "FrameChunk_*.module.lua"
        )
    )

    if (
        missing
        or len(final_chunks) != expected_chunks
    ):
        raise RuntimeError(
            f"輸出檢查失敗！\n"
            f"缺少檔案：{missing}\n"
            f"預期 Chunk：{expected_chunks}\n"
            f"實際 Chunk：{len(final_chunks)}"
        )

    print("\n========== 轉換完成 ==========")
    print(f"輸出位置：{output.resolve()}")
    print(f"影格總數：{total_frames:,}")
    print(f"Chunk 數量：{len(final_chunks)}")
    print("Config：已建立")
    print("ColorPalette：已建立")
    print(
        f"耗時：{time.time() - start_time:.1f} 秒"
    )
    print("==============================")

    if os.name == "nt":
        os.startfile(
            str(output.resolve())
        )
    else:
        print(
            f"請手動開啟：{output.resolve()}"
        )


if __name__ == "__main__":
    try:
        main()

    except KeyboardInterrupt:
        print("\n已取消轉換。")

    except Exception:
        print("\n轉換失敗，詳細錯誤如下：")
        traceback.print_exc()

    input("\n按 Enter 關閉視窗……")