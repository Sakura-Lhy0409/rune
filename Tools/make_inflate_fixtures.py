#!/usr/bin/env python3
"""生成 Inflate 测试夹具（预先用真实 zlib 压缩好的字节）。

⚠️ 为什么夹具要入库、而不是在测试里现场压缩：
   ① 测试的目标是「我们的 inflate 符合 RFC 1951」，所以**真值必须来自另一个实现**
      （zlib）。如果测试自己压自己解，只能证明自洽，证明不了正确。
   ② CI 跑在 ubuntu 与 macOS 上，测试进程里没有现成的 zlib 绑定可用，
      现场生成会让测试依赖环境。入库夹具让测试变成纯数据驱动。

用法：python3 Tools/make_inflate_fixtures.py
      （只在需要新增/更新夹具时跑；产物提交进仓库）
"""
import pathlib
import zlib

HERE = pathlib.Path(__file__).resolve().parent.parent
OUT = HERE / "Packages/RuneKernel/Tests/RuneKernelTests/Fixtures"

FIXTURES = {
    # git blob 的原始存储形态：`blob <len>\0` + 内容（这正是 inflate 要面对的输入）
    "git-blob-hello.txt.zlib": b"blob 12\x00hello\nworld\n",
    # 高压缩比：10000 个相同字节 → 大量 distance=1 的游程复制
    "repeat-10000-zlib.bin": b"A" * 10000,
    # 混合内容：游程 + 字面量 + 长距离回溯，覆盖固定/动态两种块
    "mixed-text.zlib": (b"the quick brown fox jumps over the lazy dog\n" * 200),
    # 空内容
    "empty.zlib": b"",
}


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, payload in FIXTURES.items():
        # level 9：强制走动态 Huffman + 尽量多的游程，覆盖更多解码分支
        data = zlib.compress(payload, 9)
        (OUT / name).write_bytes(data)
        # 自检：必须能原样解回（否则夹具本身就是坏的）
        assert zlib.decompress(data) == payload, name
        print(f"  {name:28s} {len(payload):8d} → {len(data):6d} 字节")
    print(f"\n夹具目录：{OUT.relative_to(HERE)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
