# -*- coding: utf-8 -*-
import sys
import os
import subprocess


def install_missing():
    required = {"customtkinter": "customtkinter"}
    missing = []
    for module, pkg in required.items():
        try:
            __import__(module)
        except ImportError:
            missing.append(pkg)
    if missing:
        for pkg in missing:
            subprocess.check_call([sys.executable, "-m", "pip", "install", pkg])

install_missing()

import shutil
import threading
import urllib.request
import zipfile
import customtkinter as ctk
from tkinter import filedialog, messagebox

ctk.set_appearance_mode("System")
ctk.set_default_color_theme("blue")

SUPPORTED_EXTS = {".mp4", ".mov", ".avi", ".mkv"}

# ffmpeg 便携版下载地址（gyan.dev 官方构建，无需安装）
FFMPEG_URL = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
FFMPEG_DIR = os.path.join(os.path.expanduser("~"), ".ffmpeg_portable")
FFMPEG_EXE = os.path.join(FFMPEG_DIR, "ffmpeg.exe")


def find_ffmpeg():
    # 1. 系统 PATH
    if shutil.which("ffmpeg"):
        return shutil.which("ffmpeg")
    # 2. 便携版
    if os.path.isfile(FFMPEG_EXE):
        return FFMPEG_EXE
    # 3. 常见安装路径
    candidates = [
        r"C:\ffmpeg\bin\ffmpeg.exe",
        r"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
        r"C:\Program Files (x86)\ffmpeg\bin\ffmpeg.exe",
    ]
    for path in candidates:
        if os.path.isfile(path):
            return path
    return None


def install_ffmpeg_winget():
    try:
        result = subprocess.run(
            ["winget", "install", "ffmpeg", "--accept-source-agreements", "--accept-package-agreements"],
            capture_output=True, timeout=120,
            creationflags=subprocess.CREATE_NO_WINDOW
        )
        return result.returncode == 0
    except Exception:
        return False


def install_ffmpeg_portable(progress_cb=None):
    """下载 ffmpeg 便携版到用户目录，不需要管理员权限"""
    try:
        os.makedirs(FFMPEG_DIR, exist_ok=True)
        zip_path = os.path.join(FFMPEG_DIR, "ffmpeg.zip")

        # 下载
        def reporthook(count, block_size, total_size):
            if progress_cb and total_size > 0:
                pct = min(count * block_size / total_size, 1.0)
                progress_cb(pct, "下载中 {:.0f}%".format(pct * 100))

        urllib.request.urlretrieve(FFMPEG_URL, zip_path, reporthook)

        if progress_cb:
            progress_cb(0.95, "正在解压...")

        # 解压，找到 ffmpeg.exe
        with zipfile.ZipFile(zip_path, "r") as z:
            for name in z.namelist():
                if name.endswith("/bin/ffmpeg.exe"):
                    data = z.read(name)
                    with open(FFMPEG_EXE, "wb") as f:
                        f.write(data)
                    break

        os.remove(zip_path)

        if os.path.isfile(FFMPEG_EXE):
            if progress_cb:
                progress_cb(1.0, "安装完成")
            return True
        return False
    except Exception as e:
        return False


class VideoAudioExtractor(ctk.CTk):
    def __init__(self):
        super().__init__()
        self.title("视频音频批量提取工具")
        self.geometry("660x560")
        self.resizable(False, False)

        self.input_dir = ctk.StringVar()
        self.output_dir = ctk.StringVar()
        self.output_format = ctk.StringVar(value="mp3")
        self.status_text = ctk.StringVar(value="准备就绪")

        self.ffmpeg_path = find_ffmpeg()

        if self.ffmpeg_path:
            ffmpeg_status = "ffmpeg 已就绪"
            color = "green"
        else:
            ffmpeg_status = "未检测到 ffmpeg，请点击下方按钮自动安装"
            color = "red"

        self.ffmpeg_label = ctk.CTkLabel(self, text=ffmpeg_status, text_color=color, wraplength=620)
        self.ffmpeg_label.pack(pady=(14, 2))

        if not self.ffmpeg_path:
            self.install_btn = ctk.CTkButton(
                self, text="一键安装 ffmpeg", command=self.auto_install_ffmpeg, fg_color="orange", height=36
            )
            self.install_btn.pack(pady=(0, 4))

        # 安装进度条（默认隐藏）
        self.install_progress = ctk.CTkProgressBar(self, width=580)
        self.install_progress.set(0)

        ctk.CTkLabel(self, text="选择视频所在文件夹：", anchor="w").pack(fill="x", padx=30, pady=(10, 0))
        row1 = ctk.CTkFrame(self, fg_color="transparent")
        row1.pack(fill="x", padx=30)
        ctk.CTkEntry(row1, textvariable=self.input_dir, width=450).pack(side="left")
        ctk.CTkButton(row1, text="浏览", width=90, command=self.select_input_dir).pack(side="left", padx=(8, 0))

        ctk.CTkLabel(self, text="输出目录（留空则保存到原文件夹）：", anchor="w").pack(fill="x", padx=30, pady=(12, 0))
        row2 = ctk.CTkFrame(self, fg_color="transparent")
        row2.pack(fill="x", padx=30)
        ctk.CTkEntry(row2, textvariable=self.output_dir, width=450).pack(side="left")
        ctk.CTkButton(row2, text="浏览", width=90, command=self.select_output_dir).pack(side="left", padx=(8, 0))

        ctk.CTkLabel(self, text="导出音频格式：", anchor="w").pack(fill="x", padx=30, pady=(12, 0))
        ctk.CTkOptionMenu(self, values=["mp3", "wav", "aac", "flac"], variable=self.output_format, width=130).pack(anchor="w", padx=30)

        ctk.CTkLabel(self, text="检测到的视频文件：", anchor="w").pack(fill="x", padx=30, pady=(12, 0))
        self.file_listbox = ctk.CTkTextbox(self, height=80, state="disabled")
        self.file_listbox.pack(fill="x", padx=30)
        self.input_dir.trace_add("write", lambda *_: self.refresh_file_list())

        self.progress = ctk.CTkProgressBar(self, width=580)
        self.progress.set(0)
        self.progress.pack(pady=(14, 0))

        self.run_btn = ctk.CTkButton(self, text="开始批量提取", command=self.start_extract, height=40)
        self.run_btn.pack(pady=10)

        ctk.CTkLabel(self, textvariable=self.status_text, text_color="green", wraplength=620).pack(pady=2)

    def auto_install_ffmpeg(self):
        self.install_btn.configure(state="disabled", text="正在安装，请稍候...")
        self.install_progress.pack(after=self.install_btn, pady=(2, 0))
        self.install_progress.set(0)
        self.status_text.set("正在尝试通过 winget 安装 ffmpeg...")
        self.update()

        def do_install():
            # 先尝试 winget
            ok = install_ffmpeg_winget()
            self.ffmpeg_path = find_ffmpeg()

            if not self.ffmpeg_path:
                # winget 失败，改用便携版下载
                self.status_text.set("winget 安装失败，正在下载便携版...")
                self.update()

                def progress_cb(pct, msg):
                    self.install_progress.set(pct)
                    self.status_text.set(msg)
                    self.update()

                install_ffmpeg_portable(progress_cb)
                self.ffmpeg_path = find_ffmpeg()

            if self.ffmpeg_path:
                self.ffmpeg_label.configure(text="ffmpeg 已就绪", text_color="green")
                self.install_btn.pack_forget()
                self.install_progress.pack_forget()
                self.status_text.set("ffmpeg 安装成功！可以开始提取音频了")
            else:
                self.install_btn.configure(state="normal", text="一键安装 ffmpeg")
                self.install_progress.pack_forget()
                self.status_text.set("安装失败，请检查网络连接后重试")

        threading.Thread(target=do_install, daemon=True).start()

    def select_input_dir(self):
        folder = filedialog.askdirectory()
        if folder:
            self.input_dir.set(folder)

    def select_output_dir(self):
        folder = filedialog.askdirectory()
        if folder:
            self.output_dir.set(folder)

    def get_video_files(self):
        folder = self.input_dir.get().strip()
        if not os.path.isdir(folder):
            return []
        return [f for f in os.listdir(folder) if os.path.splitext(f)[1].lower() in SUPPORTED_EXTS]

    def refresh_file_list(self):
        files = self.get_video_files()
        self.file_listbox.configure(state="normal")
        self.file_listbox.delete("1.0", "end")
        self.file_listbox.insert("end", "\n".join(files) if files else "未检测到支持的视频文件")
        self.file_listbox.configure(state="disabled")

    def start_extract(self):
        if not self.ffmpeg_path:
            messagebox.showerror("错误", "未找到 ffmpeg，请先点击一键安装按钮")
            return
        files = self.get_video_files()
        if not files:
            messagebox.showerror("错误", "所选文件夹内没有支持的视频文件")
            return
        self.run_btn.configure(state="disabled")
        threading.Thread(target=self.extract_all, args=(files,), daemon=True).start()

    def extract_all(self, files):
        input_folder = self.input_dir.get().strip()
        output_folder = self.output_dir.get().strip() or input_folder
        out_format = self.output_format.get()

        os.makedirs(output_folder, exist_ok=True)
        success, failed = 0, []
        total = len(files)

        for i, filename in enumerate(files):
            self.status_text.set("处理中 (" + str(i+1) + "/" + str(total) + ")：" + filename)
            self.progress.set(i / total)
            self.update()

            video_path = os.path.join(input_folder, filename)
            base_name = os.path.splitext(filename)[0]
            out_path = os.path.join(output_folder, base_name + "." + out_format)

            if out_format == "mp3":
                cmd = [self.ffmpeg_path, "-i", video_path, "-vn", "-acodec", "libmp3lame", "-q:a", "2", "-y", out_path]
            elif out_format == "wav":
                cmd = [self.ffmpeg_path, "-i", video_path, "-vn", "-acodec", "pcm_s16le", "-y", out_path]
            elif out_format == "flac":
                cmd = [self.ffmpeg_path, "-i", video_path, "-vn", "-acodec", "flac", "-y", out_path]
            elif out_format == "aac":
                cmd = [self.ffmpeg_path, "-i", video_path, "-vn", "-acodec", "copy", "-y", out_path]
            else:
                cmd = [self.ffmpeg_path, "-i", video_path, "-vn", "-y", out_path]

            try:
                result = subprocess.run(cmd, capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW)
                stderr = result.stderr.decode("utf-8", errors="ignore")
                if result.returncode == 0:
                    success += 1
                else:
                    failed.append(filename + "：" + stderr[-200:])
            except Exception as e:
                failed.append(filename + "：" + str(e))

        self.progress.set(1.0)
        self.status_text.set("完成！成功 " + str(success) + " 个，失败 " + str(len(failed)) + " 个")
        self.run_btn.configure(state="normal")

        if failed:
            messagebox.showwarning("部分失败", "\n".join(failed))
        else:
            messagebox.showinfo("完成", "全部 " + str(success) + " 个文件提取成功！\n保存至：" + output_folder)


if __name__ == "__main__":
    app = VideoAudioExtractor()
    app.mainloop()
