/**
 * 把子进程退出码翻译成人能看懂的原因。
 * Windows 的 NTSTATUS 是 32 位无符号数，Node 里可能以正数形式出现（超过 2^31）。
 */
export function explainExitCode(code: number | null): string {
  if (code === null) return '进程异常结束'
  const unsigned = code >>> 0
  const hex = `0x${unsigned.toString(16).toUpperCase().padStart(8, '0')}`

  if (unsigned === 0xc000001d) {
    return (
      `退出码 ${code}（${hex}，STATUS_ILLEGAL_INSTRUCTION）：` +
      '该 AI 引擎二进制使用了当前 CPU 不支持的指令集（常见于 AVX-512，' +
      'Intel 第 12 代及以后的消费级 CPU 已将其禁用）。' +
      '请用 `GGML_NATIVE=OFF` 重新编译引擎，或换用不含 AVX-512 的构建。'
    )
  }
  if (unsigned === 0xc0000005) {
    return `退出码 ${code}（${hex}，STATUS_ACCESS_VIOLATION）：引擎访问了非法内存，可能是模型文件损坏或内存不足。`
  }
  if (unsigned === 0xc0000135) {
    return `退出码 ${code}（${hex}，STATUS_DLL_NOT_FOUND）：缺少运行库 DLL，请确认引擎同目录下的 DLL 完整。`
  }
  if (unsigned === 0xc000007b) {
    return `退出码 ${code}（${hex}，STATUS_INVALID_IMAGE_FORMAT）：二进制与运行库位数/架构不匹配（例如 32/64 位不符）。`
  }
  return `退出码 ${code}（${hex}）`
}
