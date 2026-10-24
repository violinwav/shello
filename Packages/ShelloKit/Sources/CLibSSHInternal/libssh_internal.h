// Declarations of libssh 0.12.2 functions that its installed headers leave out, copied from
// libssh's include/libssh/channels.h. Vendor/README.md asks to check them on every libssh update:
// a declaration that no longer matches the library would call it wrongly.

#ifndef SHELLO_LIBSSH_INTERNAL_H
#define SHELLO_LIBSSH_INTERNAL_H

struct ssh_session_struct;
struct ssh_buffer_struct;

// Sends the global request `request`, with `buffer` after its name, and with `reply` set waits for
// the server's answer. Non-blocking, it returns SSH_AGAIN until the answer has arrived, then SSH_OK
// for a success, or SSH_ERROR with the error code SSH_REQUEST_DENIED for a failure. libssh's own
// keepalive, `ssh_send_keepalive`, sends `keepalive@openssh.com` this way, but is built only with
// the server part of libssh, which Shello leaves out.
int ssh_global_request(struct ssh_session_struct *session, const char *request,
                       struct ssh_buffer_struct *buffer, int reply);

#endif
