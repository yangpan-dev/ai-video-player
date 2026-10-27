import AppKit
import OpenGL.GL3
import CMPV
import PlayerCore

// Integration test of the real libmpv GPU pipeline into our own offscreen FBO.
// This does not capture or automate the user's desktop.
final class RenderProbe {
    private let engine: MPVEngine
    private let context: NSOpenGLContext
    private var framebuffer: GLuint = 0
    private var texture: GLuint = 0
    private let width = 1280, height = 720

    init(engine: MPVEngine) throws {
        self.engine = engine
        let attributes: [NSOpenGLPixelFormatAttribute] = [UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core), UInt32(NSOpenGLPFAAccelerated), UInt32(NSOpenGLPFAColorSize), 24, 0]
        guard let format = NSOpenGLPixelFormat(attributes: attributes), let context = NSOpenGLContext(format: format, share: nil), let handle = engine.handle else { throw EngineError.unavailable("Offscreen OpenGL context unavailable") }
        self.context = context
        context.makeCurrentContext()
        glGenFramebuffers(1, &framebuffer); glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glGenTextures(1, &texture); glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, GLsizei(width), GLsizei(height), 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
        guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else { throw EngineError.unavailable("Incomplete OpenGL framebuffer") }
        let result = lumen_render_create(handle, { _, name in
            guard let name else { return nil }
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }, nil)
        guard result >= 0 else { throw EngineError.operation("Offscreen renderer", result) }
    }
    func draw() {
        context.makeCurrentContext(); glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        if let handle = engine.handle { lumen_render(handle, Int32(width), Int32(height), Int32(framebuffer)) }
        glFinish()
    }
    private func settle() {
        for _ in 0..<12 { engine.pollEvents(); draw(); Thread.sleep(forTimeInterval: 0.02) }
    }
    private func pixels() -> [UInt8] {
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        glReadPixels(0, 0, GLsizei(width), GLsizei(height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &buffer)
        return buffer
    }
    private func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total = 0
        for i in stride(from: 0, to: a.count, by: 4) { total += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i+1]) - Int(b[i+1])) + abs(Int(a[i+2]) - Int(b[i+2])) }
        return Double(total) / Double(width * height * 3)
    }
    func verifyPictureOutput(file: URL) throws {
        _ = engine.apply(PicturePreset.original.settings); settle()
        let original = pixels()
        guard original.enumerated().contains(where: { $0.offset % 4 != 3 && $0.element > 40 }) else { throw EngineError.unavailable("Rendered video is black") }
        var adjusted = PicturePreset.balanced.settings
        adjusted.brightness = 20; adjusted.contrast = 8; adjusted.denoise = true
        let failures = engine.apply(adjusted)
        guard failures.isEmpty else { throw EngineError.unavailable("Render settings: \(failures)") }
        settle()
        let enhanced = pixels(), delta = difference(original, enhanced)
        guard delta > 2 else { throw EngineError.unavailable("Picture controls did not change rendered pixels (delta \(delta))") }
        _ = engine.apply(PicturePreset.original.settings); settle()
        let restored = pixels(), restoration = difference(original, restored)
        guard restoration < 3 else { throw EngineError.unavailable("Original comparison did not restore image (delta \(restoration))") }
        print("RENDER PASS: \(file.lastPathComponent), color delta=\(String(format: "%.2f", delta)), restore delta=\(String(format: "%.2f", restoration))")
    }
    func close() {
        context.makeCurrentContext()
        if let handle = engine.handle { lumen_render_destroy(handle) }
        glDeleteFramebuffers(1, &framebuffer); glDeleteTextures(1, &texture)
    }
}
