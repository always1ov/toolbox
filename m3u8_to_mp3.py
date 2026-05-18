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

FFMPEG_URL = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
FFMPEG_DIR = os.path.join(os.path.expanduser("~"), ".ffmpeg_portable")
FFMPEG_EXE = os.path.join(FFMPEG_DIR, "ffmpeg.exe")


def find_ffmpeg():
    if shutil.which("ffmpeg"):
        return shutil.which("ffmpeg")
    if os.path.isfile(FFMPEG_EXE):
        return FFMPEG_EXE
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
    try:
        os.makedirs(FFMPEG_DIR, exist_ok=True)
        zip_path = os.path.join(FFMPEG_DIR, "ffmpeg.zip")

        def reporthook(count, block_size, total_size):
            if progress_cb and total_size > 0:
                pct = min(count * block_size / total_size, 1.0)
                progress_cb(pct, "下载中 {:.0f}%".format(pct * 100))

        urllib.request.urlretrieve(FFMPEG_URL, zip_path, reporthook)

        if progress_cb:
            progress_cb(0.95, "正在解压...")

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
    except Exception:
        return False


class M3u8ToMp3(ctk.CTk):
    def __init__(self):
        super().__init__()
        self.title("本地 m3u8 → MP3 批量转换")
        self.geometry("660x560")
        self.resizable(False, False)

        self.m3u8_files = []
        self.output_dir = ctk.StringVar()
        self.output_format = ctk.StringVar(value="mp3")
        self.status_text = ctk.StringVar(value="准备就绪")
        self.ffmpeg_path = find_ffmpeg()

        if self.ffmpeg_path:
            ffmpeg_status = "✅ ffmpeg 已就绪"
            color = "green"
        else:
            ffmpeg_status = "❌ 未检测到 ffmpeg，请点击下方按钮自动安装"
            color = "red"

        self.ffmpeg_label = ctk.CTkLabel(self, text=ffmpeg_status, text_color=color, wraplength=640)
        self.ffmpeg_label.pack(pady=(14, 2))

        if not self.ffmpeg_path:
            self.install_btn = ctk.CTkButton(
                self, text="一键安装 ffmpeg", command=self.auto_install_ffmpeg,
                fg_color="orange", height=36
            )
            self.install_btn.pack(pady=(0, 4))

        self.install_progress = ctk.CTkProgressBar(self, width=600)
        self.install_progress.set(0)

        # 选择文件
        ctk.CTkLabel(self, text="选择本地 m3u8 文件（支持多选）：", anchor="w").pack(fill="x", padx=30, pady=(12, 0))
        btn_row = ctk.CTkFrame(self, fg_color="transparent")
        btn_row.pack(fill="x", padx=30)
        ctk.CTkButton(btn_row, text="添加文件", width=110, command=self.add_files).pack(side="left")
        ctk.CTkButton(btn_row, text="清空列表", width=110, command=self.clear_files, fg_color="gray").pack(side="left", padx=(8, 0))

        self.file_listbox = ctk.CTkTextbox(self, height=130, state="disabled")
        self.file_listbox.pack(fill="x", padx=30, pady=(6, 0))

        # 输出目录
        ctk.CTkLabel(self, text="保存目录（留空则保存到各 m3u8 文件所在目录）：", anchor="w").pack(fill="x", padx=30, pady=(10, 0))
        row = ctk.CTkFrame(self, fg_color="transparent")
        row.pack(fill="x", padx=30)
        ctk.CTkEntry(row, textvariable=self.output_dir, width=460).pack(side="left")
        ctk.CTkButton(row, text="浏览", width=90, command=self.select_output_dir).pack(side="left", padx=(8, 0))

        # 格式
        fmt_row = ctk.CTkFrame(self, fg_color="transparent")
        fmt_row.pack(fill="x", padx=30, pady=(10, 0))
        ctk.CTkLabel(fmt_row, text="导出格式：").pack(side="left")
        ctk.CTkOptionMenu(fmt_row, values=["mp3", "wav", "aac", "flac"], variable=self.output_format, width=110).pack(side="left", padx=(8, 0))

        # 进度 & 按钮
        self.progress = ctk.CTkProgressBar(self, width=600)
        self.progress.set(0)
        self.progress.pack(pady=(14, 0))

        self.run_btn = ctk.CTkButton(self, text="🚀 开始批量转换", command=self.start, height=42)
        self.run_btn.pack(pady=10)

        ctk.CTkLabel(self, textvariable=self.status_text, text_color="green", wraplength=640).pack(pady=2)

    def auto_install_ffmpeg(self):
        self.install_btn.configure(state="disabled", text="正在安装，请稍候...")
        self.install_progress.pack(after=self.install_btn, pady=(2, 0))
        self.install_progress.set(0)
        self.status_text.set("正在尝试通过 winget 安装 ffmpeg...")
        self.update()

        def do_install():
            install_ffmpeg_winget()
            self.ffmpeg_path = find_ffmpeg()
            if not self.ffmpeg_path:
                self.status_text.set("winget 失败，正在下载便携版...")
                self.update()
                install_ffmpeg_portable(lambda pct, msg: (
                    self.install_progress.set(pct),
                    self.status_text.set(msg),
                    self.update()
                ))
                self.ffmpeg_path = find_ffmpeg()

            if self.ffmpeg_path:
                self.ffmpeg_label.configure(text="✅ ffmpeg 已就绪", text_color="green")
                self.install_btn.pack_forget()
                self.install_progress.pack_forget()
                self.status_text.set("ffmpeg 安装成功！可以开始转换了")
            else:
                self.install_btn.configure(state="normal", text="一键安装 ffmpeg")
                self.install_progress.pack_forget()
                self.status_text.set("安装失败，请检查网络后重试")

        threading.Thread(target=do_install, daemon=True).start()

    def add_files(self):
        paths = filedialog.askopenfilenames(
            title="选择 m3u8 文件",
            filetypes=[("M3U8 文件", "*.m3u8"), ("所有文件", "*.*")]
        )
        for p in paths:
            if p not in self.m3u8_files:
                self.m3u8_files.append(p)
        self.refresh_list()

    def clear_files(self):
        self.m3u8_files.clear()
        self.refresh_list()

    def refresh_list(self):
        self.file_listbox.configure(state="normal")
        self.file_listbox.delete("1.0", "end")
        if self.m3u8_files:
            for p in self.m3u8_files:
                self.file_listbox.insert("end", os.path.basename(p) + "\n")
        else:
            self.file_listbox.insert("end", "尚未添加文件")
        self.file_listbox.configure(state="disabled")

    def select_output_dir(self):
        folder = filedialog.askdirectory()
        if folder:
            self.output_dir.set(folder)

    def start(self):
        if not self.ffmpeg_path:
            messagebox.showerror("错误", "未找到 ffmpeg，请先安装")
            return
        if not self.m3u8_files:
            messagebox.showerror("错误", "请先添加 m3u8 文件")
            return
        self.run_btn.configure(state="disabled")
        threading.Thread(target=self.convert_all, daemon=True).start()

    def convert_all(self):
        out_format = self.output_format.get()
        total = len(self.m3u8_files)
        success, failed = 0, []

        for i, m3u8_path in enumerate(self.m3u8_files):
            basename = os.path.splitext(os.path.basename(m3u8_path))[0]
            self.status_text.set("处理中 ({}/{})：{}".format(i + 1, total, basename))
            self.progress.set(i / total)
            self.update()

            out_folder = self.output_dir.get().strip() or os.path.dirname(m3u8_path)
            os.makedirs(out_folder, exist_ok=True)
            out_path = os.path.join(out_folder, basename + "." + out_format)

            # 本地 m3u8：ts 碎片在同目录，需要 file+crypto 白名单
            cmd = [
                self.ffmpeg_path,
                "-allowed_extensions", "ALL",
                "-protocol_whitelist", "file,crypto",
                "-i", m3u8_path,
                "-vn",
            ]

            if out_format == "mp3":
                cmd += ["-acodec", "libmp3lame", "-q:a", "2"]
            elif out_format == "wav":
                cmd += ["-acodec", "pcm_s16le"]
            elif out_format == "flac":
                cmd += ["-acodec", "flac"]
            elif out_format == "aac":
                cmd += ["-acodec", "aac", "-b:a", "192k"]

            cmd += ["-y", out_path]

            try:
                result = subprocess.run(
                    cmd,
                    capture_output=True,
                    creationflags=subprocess.CREATE_NO_WINDOW
                )
                if result.returncode == 0:
                    success += 1
                else:
                    err = result.stderr.decode("utf-8", errors="ignore")[-300:]
                    failed.append("{} 失败：{}".format(basename, err))
            except Exception as e:
                failed.append("{} 异常：{}".format(basename, str(e)))

        self.progress.set(1.0)
        self.status_text.set("完成！成功 {} 个，失败 {} 个".format(success, len(failed)))
        self.run_btn.configure(state="normal")

        if failed:
            messagebox.showwarning("部分失败", "\n\n".join(failed))
        else:
            out_folder = self.output_dir.get().strip() or "各文件所在目录"
            messagebox.showinfo("完成", "全部 {} 个文件转换成功！\n保存至：{}".format(success, out_folder))


if __name__ == "__main__":
    app = M3u8ToMp3()
    app.mainloop()
