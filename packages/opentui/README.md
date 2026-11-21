# OpenTUI bindings

PureScript builds a typed tree of `box` and `text` nodes and calls `render`.
The FFI only maps these nodes to OpenTUI's native renderables and forwards key,
resize, clipboard and renderer lifecycle operations. OpenTUI provides Unicode
measurement, flexbox layout and native frame rendering. Renderer creation and
shutdown use `Aff`; shutdown awaits native terminal restoration.
