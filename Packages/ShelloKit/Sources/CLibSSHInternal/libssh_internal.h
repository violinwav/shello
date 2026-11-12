// Declarations of libssh 0.12.2 functions that its installed headers leave out, copied from
// libssh's include/libssh/channels.h and include/libssh/wrapper.h. Vendor/README.md asks to check
// them on every libssh update: a declaration that no longer matches the library would call it
// wrongly.

#ifndef SHELLO_LIBSSH_INTERNAL_H
#define SHELLO_LIBSSH_INTERNAL_H

#include <stddef.h>

struct ssh_session_struct;
struct ssh_buffer_struct;

// Sends the global request `request`, with `buffer` after its name, and with `reply` set waits for
// the server's answer. Non-blocking, it returns SSH_AGAIN until the answer has arrived, then SSH_OK
// for a success, or SSH_ERROR with the error code SSH_REQUEST_DENIED for a failure. libssh's own
// keepalive, `ssh_send_keepalive`, sends `keepalive@openssh.com` this way, but is built only with
// the server part of libssh, which Shello leaves out.
int ssh_global_request(struct ssh_session_struct *session, const char *request,
                       struct ssh_buffer_struct *buffer, int reply);

// libssh's HMAC, over OpenSSL's, for the hashed names of a known_hosts file (`KnownHostKeys`), which
// OpenSSH hashes with HMAC-SHA1. From wrapper.h, where the context is OpenSSL's `EVP_MD_CTX *`
// (libcrypto.h); only its pointer is passed around.
enum ssh_hmac_e {
  SSH_HMAC_SHA1 = 1,
  SSH_HMAC_SHA256,
  SSH_HMAC_SHA512,
  SSH_HMAC_MD5,
  SSH_HMAC_AEAD_POLY1305,
  SSH_HMAC_AEAD_GCM,
  SSH_HMAC_NONE,
};

struct evp_md_ctx_st;

// A context for the HMAC of `type` keyed with the `len` bytes at `key`, or NULL.
struct evp_md_ctx_st *hmac_init(const void *key, size_t len, enum ssh_hmac_e type);
// Adds `len` bytes at `data` to the message. Returns 1 on success.
int hmac_update(struct evp_md_ctx_st *c, const void *data, size_t len);
// Writes the HMAC to `hashmacbuf`, which holds `*len` bytes, sets `*len` to its length, and frees
// the context. Returns 1 on success.
int hmac_final(struct evp_md_ctx_st *ctx, unsigned char *hashmacbuf, size_t *len);

#endif
