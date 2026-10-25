/// A pointer to one of libssh's objects: a session, a channel, an event or a key. Handles never
/// leave the connection that owns them, which uses them on its own queue only and stops using a
/// handle before libssh frees what it points to, so a handle is safe to keep and pass around there.
/// Each libssh call that takes `pointer` is marked `unsafe`.
@safe
struct Handle {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        unsafe self.pointer = pointer
    }
}
