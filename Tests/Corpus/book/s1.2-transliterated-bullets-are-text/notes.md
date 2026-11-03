A bullet becomes `*`, after the markup is read (§1.2 step 5 runs per token), so it's a literal `*`: no
italic between two bullets, no bold from `••`. The serializer escapes each `*` it writes.
