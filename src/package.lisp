;;;; package.lisp

(defpackage #:ghostty-vt.ffi
  (:use #:cl)
  (:documentation "Raw CFFI bindings to libghostty-vt. Names mirror the C API
with the ghostty_ prefix replaced by %. Prefer the GHOSTTY-VT package.")
  (:export
   ;; library
   #:libghostty-vt #:load-libghostty-vt #:*library-path* #:load-shim #:*shim-path*
   ;; results
   #:+success+ #:+out-of-memory+ #:+invalid-value+ #:+out-of-space+
   #:+no-value+ #:+io-error+ #:+limit-exceeded+ #:+rejected+
   ;; terminal options / data
   #:+opt-userdata+ #:+opt-write-pty+ #:+opt-bell+ #:+opt-title-changed+
   #:+opt-title+
   #:+data-cols+ #:+data-rows+ #:+data-cursor-x+ #:+data-cursor-y+
   #:+data-cursor-pending-wrap+ #:+data-active-screen+ #:+data-cursor-visible+
   #:+data-title+ #:+data-mode+
   #:+point-tag-active+ #:+point-tag-viewport+ #:+point-tag-screen+ #:+point-tag-history+
   ;; cell data
   #:+cell-data-codepoint+ #:+cell-data-content-tag+ #:+cell-data-wide+
   #:+cell-data-has-text+ #:+cell-data-has-styling+ #:+cell-data-color-palette+
   #:+cell-data-color-rgb+
   #:+cell-content-codepoint+ #:+cell-content-codepoint-grapheme+
   #:+cell-content-bg-color-palette+ #:+cell-content-bg-color-rgb+
   #:+cell-wide-narrow+ #:+cell-wide-wide+ #:+cell-wide-spacer-tail+ #:+cell-wide-spacer-head+
   #:+style-color-none+ #:+style-color-palette+ #:+style-color-rgb+
   #:+formatter-format-plain+ #:+formatter-format-vt+ #:+formatter-format-html+
   #:+mods-shift+ #:+mods-ctrl+ #:+mods-alt+ #:+mods-super+ #:+mods-caps-lock+
   #:+mods-num-lock+
   #:+key-action-release+ #:+key-action-press+ #:+key-action-repeat+
   #:+key-encoder-opt-cursor-key-application+ #:+key-encoder-opt-alt-esc-prefix+
   #:+key-encoder-opt-kitty-flags+ #:+key-encoder-opt-macos-option-as-alt+
   #:+option-as-alt-false+ #:+option-as-alt-true+ #:+option-as-alt-left+
   #:+option-as-alt-right+
   #:key
   ;; structs and slots
   #:ghostty-string #:ptr #:len
   #:color-rgb #:r #:g #:b
   #:style-color-value #:palette #:rgb #:padding
   #:style-color #:tag #:value
   #:style #:size #:fg-color #:bg-color #:underline-color #:bold #:italic #:faint
   #:blink #:inverse #:invisible #:strikethrough #:overline #:underline
   #:point #:x #:y
   #:grid-ref #:node
   #:mode-config #:mode
   #:formatter-screen-extra #:cursor #:hyperlink #:protection #:kitty-keyboard #:charsets
   #:formatter-terminal-extra #:modes #:scrolling-region #:tabstops #:pwd #:keyboard #:screen
   #:formatter-terminal-options #:emit #:unwrap #:trim #:extra #:selection
   ;; functions
   #:%type-json #:%free
   #:%terminal-new #:%terminal-free #:%terminal-reset #:%terminal-resize
   #:%terminal-set #:%terminal-vt-write #:%terminal-get #:%terminal-grid-ref
   #:%shim-terminal-grid-ref #:%shim-formatter-terminal-new
   #:%grid-ref-cell #:%grid-ref-style #:%grid-ref-graphemes #:%cell-get
   #:%style-default
   #:%formatter-terminal-new #:%formatter-format-alloc #:%formatter-free
   #:%key-encoder-new #:%key-encoder-free #:%key-encoder-setopt
   #:%key-encoder-setopt-from-terminal #:%key-encoder-encode
   #:%key-event-new #:%key-event-free #:%key-event-set-action #:%key-event-set-key
   #:%key-event-set-mods #:%key-event-set-consumed-mods #:%key-event-set-utf8
   #:%key-event-set-unshifted-codepoint
   ;; ABI
   #:abi-type-sizes #:check-abi))

(defpackage #:ghostty-vt
  (:use #:cl)
  (:local-nicknames (#:ffi #:ghostty-vt.ffi))
  (:documentation "Lisp interface to libghostty-vt terminal emulation.")
  (:export
   #:ghostty-error #:ghostty-error-code #:ghostty-error-operation
   #:terminal #:terminalp #:make-terminal #:terminal-free #:with-terminal
   #:terminal-live-p #:terminal-handle
   #:terminal-feed #:terminal-reset #:terminal-resize
   #:terminal-rows #:terminal-columns #:terminal-cursor #:terminal-title
   #:terminal-active-screen #:terminal-mode
   #:terminal-cell #:terminal-row-text #:terminal-screen-text
   #:terminal-pty-write-function #:terminal-bell-function #:terminal-title-function
   #:cell #:cellp #:cell-codepoints #:cell-string #:cell-width #:cell-fg #:cell-bg
   #:cell-attrs
   #:encode-key))
