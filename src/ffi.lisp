;;;; ffi.lisp -- raw bindings to the libghostty-vt C API
;;;;
;;;; Mirrors include/ghostty/vt/*.h at the pinned Ghostty commit (see
;;;; README.md). C enums are declared GHOSTTY_ENUM_TYPED (int), so enum
;;;; arguments are bound as :int and their values as constants, except for
;;;; GhosttyKey which is a CFFI enum because it is long and purely sequential.
;;;; C bool fields are bound as :uint8 to keep struct layout explicit.

(in-package #:ghostty-vt.ffi)

;;; ------------------------------------------------------------------
;;; Constants

(defmacro defconstants (&body pairs)
  `(progn ,@(loop for (name value) on pairs by #'cddr
                  collect `(defconstant ,name ,value))))

;; GhosttyResult (types.h)
(defconstants
  +success+ 0 +out-of-memory+ -1 +invalid-value+ -2 +out-of-space+ -3
  +no-value+ -4 +io-error+ -5 +limit-exceeded+ -6 +rejected+ -7)

;; GhosttyTerminalOption (terminal.h)
(defconstants
  +opt-userdata+ 0 +opt-write-pty+ 1 +opt-bell+ 2 +opt-title-changed+ 5
  +opt-title+ 9)

;; GhosttyTerminalData (terminal.h)
(defconstants
  +data-cols+ 1 +data-rows+ 2 +data-cursor-x+ 3 +data-cursor-y+ 4
  +data-cursor-pending-wrap+ 5 +data-active-screen+ 6
  +data-cursor-visible+ 7 +data-title+ 12 +data-mode+ 37)

;; GhosttyPointTag (point.h)
(defconstants
  +point-tag-active+ 0 +point-tag-viewport+ 1 +point-tag-screen+ 2
  +point-tag-history+ 3)

;; GhosttyCellData, GhosttyCellContentTag, GhosttyCellWide (screen.h)
(defconstants
  +cell-data-codepoint+ 1 +cell-data-content-tag+ 2 +cell-data-wide+ 3
  +cell-data-has-text+ 4 +cell-data-has-styling+ 5
  +cell-data-color-palette+ 10 +cell-data-color-rgb+ 11
  +cell-content-codepoint+ 0 +cell-content-codepoint-grapheme+ 1
  +cell-content-bg-color-palette+ 2 +cell-content-bg-color-rgb+ 3
  +cell-wide-narrow+ 0 +cell-wide-wide+ 1 +cell-wide-spacer-tail+ 2
  +cell-wide-spacer-head+ 3)

;; GhosttyStyleColorTag (style.h)
(defconstants +style-color-none+ 0 +style-color-palette+ 1 +style-color-rgb+ 2)

;; GhosttyFormatterFormat (types.h)
(defconstants
  +formatter-format-plain+ 0 +formatter-format-vt+ 1 +formatter-format-html+ 2)

;; GhosttyMods bits and GhosttyKeyAction (key/event.h)
(defconstants
  +mods-shift+ 1 +mods-ctrl+ 2 +mods-alt+ 4 +mods-super+ 8
  +mods-caps-lock+ 16 +mods-num-lock+ 32
  +key-action-release+ 0 +key-action-press+ 1 +key-action-repeat+ 2)

;; GhosttyKeyEncoderOption and GhosttyOptionAsAlt (key/encoder.h)
(defconstants
  +key-encoder-opt-cursor-key-application+ 0
  +key-encoder-opt-alt-esc-prefix+ 3
  +key-encoder-opt-kitty-flags+ 5
  +key-encoder-opt-macos-option-as-alt+ 6
  +option-as-alt-false+ 0 +option-as-alt-true+ 1
  +option-as-alt-left+ 2 +option-as-alt-right+ 3)

;; GhosttyKey (key/event.h): sequential from 0, in header order.
(cffi:defcenum key
  :unidentified :backquote :backslash :bracket-left :bracket-right :comma
  :digit-0 :digit-1 :digit-2 :digit-3 :digit-4 :digit-5 :digit-6 :digit-7
  :digit-8 :digit-9 :equal :intl-backslash :intl-ro :intl-yen
  :a :b :c :d :e :f :g :h :i :j :k :l :m :n :o :p :q :r :s :t :u :v :w :x :y :z
  :minus :period :quote :semicolon :slash
  :alt-left :alt-right :backspace :caps-lock :context-menu
  :control-left :control-right :enter :meta-left :meta-right
  :shift-left :shift-right :space :tab :convert :kana-mode :non-convert
  :delete :end :help :home :insert :page-down :page-up
  :arrow-down :arrow-left :arrow-right :arrow-up
  :num-lock :numpad-0 :numpad-1 :numpad-2 :numpad-3 :numpad-4 :numpad-5
  :numpad-6 :numpad-7 :numpad-8 :numpad-9 :numpad-add :numpad-backspace
  :numpad-clear :numpad-clear-entry :numpad-comma :numpad-decimal
  :numpad-divide :numpad-enter :numpad-equal :numpad-memory-add
  :numpad-memory-clear :numpad-memory-recall :numpad-memory-store
  :numpad-memory-subtract :numpad-multiply :numpad-paren-left
  :numpad-paren-right :numpad-subtract :numpad-separator
  :numpad-up :numpad-down :numpad-right :numpad-left :numpad-begin
  :numpad-home :numpad-end :numpad-insert :numpad-delete
  :numpad-page-up :numpad-page-down
  :escape :f1 :f2 :f3 :f4 :f5 :f6 :f7 :f8 :f9 :f10 :f11 :f12 :f13 :f14 :f15
  :f16 :f17 :f18 :f19 :f20 :f21 :f22 :f23 :f24 :f25 :fn :fn-lock
  :print-screen :scroll-lock :pause
  :browser-back :browser-favorites :browser-forward :browser-home
  :browser-refresh :browser-search :browser-stop :eject
  :launch-app-1 :launch-app-2 :launch-mail
  :media-play-pause :media-select :media-stop :media-track-next
  :media-track-previous :power :sleep
  :audio-volume-down :audio-volume-mute :audio-volume-up :wake-up
  :copy :cut :paste)

;;; ------------------------------------------------------------------
;;; Structs

(cffi:defcstruct ghostty-string
  (ptr :pointer)
  (len :size))

(cffi:defcstruct color-rgb
  (r :uint8)
  (g :uint8)
  (b :uint8))

(cffi:defcunion style-color-value
  (palette :uint8)
  (rgb (:struct color-rgb))
  (padding :uint64))

(cffi:defcstruct style-color
  (tag :int)
  (value (:union style-color-value)))

(cffi:defcstruct style                  ; sized
  (size :size)
  (fg-color (:struct style-color))
  (bg-color (:struct style-color))
  (underline-color (:struct style-color))
  (bold :uint8)
  (italic :uint8)
  (faint :uint8)
  (blink :uint8)
  (inverse :uint8)
  (invisible :uint8)
  (strikethrough :uint8)
  (overline :uint8)
  (underline :int))

;; GhosttyPoint is {GhosttyPointTag tag; union {GhosttyPointCoordinate
;; {uint16_t x; uint32_t y}; uint64_t _padding[2]} value;}. It is passed by
;; value, so it is declared here as a layout-identical plain struct (libffi
;; has no union type). Being 24 bytes it travels in memory / by reference on
;; both SysV x86-64 and AAPCS64, independent of field classification.
(cffi:defcstruct point
  (tag :int :offset 0)
  (x :uint16 :offset 8)
  (y :uint32 :offset 12)
  (padding :uint64 :offset 16))

(cffi:defcstruct grid-ref               ; sized
  (size :size)
  (node :pointer)
  (x :uint16)
  (y :uint16))

(cffi:defcstruct mode-config
  (mode :uint16)
  (value :uint8))

(cffi:defcstruct formatter-screen-extra ; sized
  (size :size)
  (cursor :uint8)
  (style :uint8)
  (hyperlink :uint8)
  (protection :uint8)
  (kitty-keyboard :uint8)
  (charsets :uint8))

(cffi:defcstruct formatter-terminal-extra ; sized
  (size :size)
  (palette :uint8)
  (modes :uint8)
  (scrolling-region :uint8)
  (tabstops :uint8)
  (pwd :uint8)
  (keyboard :uint8)
  (screen (:struct formatter-screen-extra)))

(cffi:defcstruct formatter-terminal-options ; sized, passed by value
  (size :size)
  (emit :int)
  (unwrap :uint8)
  (trim :uint8)
  (extra (:struct formatter-terminal-extra))
  (selection :pointer))

;;; ------------------------------------------------------------------
;;; Functions

(cffi:defcfun ("ghostty_type_json" %type-json) :pointer)

(cffi:defcfun ("ghostty_free" %free) :void
  (allocator :pointer) (ptr :pointer) (len :size))

;; terminal.h
(cffi:defcfun ("ghostty_terminal_new" %terminal-new) :int
  (allocator :pointer) (out-terminal :pointer) (cols :uint16) (rows :uint16))

(cffi:defcfun ("ghostty_terminal_free" %terminal-free) :void
  (terminal :pointer))

(cffi:defcfun ("ghostty_terminal_reset" %terminal-reset) :void
  (terminal :pointer))

(cffi:defcfun ("ghostty_terminal_resize" %terminal-resize) :int
  (terminal :pointer) (cols :uint16) (rows :uint16)
  (cell-width-px :uint32) (cell-height-px :uint32))

(cffi:defcfun ("ghostty_terminal_set" %terminal-set) :int
  (terminal :pointer) (option :int) (value :pointer))

(cffi:defcfun ("ghostty_terminal_vt_write" %terminal-vt-write) :void
  (terminal :pointer) (data :pointer) (len :size))

(cffi:defcfun ("ghostty_terminal_get" %terminal-get) :int
  (terminal :pointer) (data :int) (out :pointer))

(cffi:defcfun ("ghostty_terminal_grid_ref" %terminal-grid-ref) :int
  (terminal :pointer) (point (:struct point)) (out-ref :pointer))

;; Shim equivalents (csrc/ghostty-vt-cl.c), taking the struct by pointer.
(cffi:defcfun ("cl_ghostty_vt_terminal_grid_ref" %shim-terminal-grid-ref) :int
  (terminal :pointer) (point :pointer) (out-ref :pointer))

(cffi:defcfun ("cl_ghostty_vt_formatter_terminal_new" %shim-formatter-terminal-new) :int
  (allocator :pointer) (out-formatter :pointer) (terminal :pointer) (options :pointer))

;; grid_ref.h / screen.h / style.h
(cffi:defcfun ("ghostty_grid_ref_cell" %grid-ref-cell) :int
  (ref :pointer) (out-cell :pointer))

(cffi:defcfun ("ghostty_grid_ref_style" %grid-ref-style) :int
  (ref :pointer) (out-style :pointer))

(cffi:defcfun ("ghostty_grid_ref_graphemes" %grid-ref-graphemes) :int
  (ref :pointer) (buf :pointer) (buf-len :size) (out-len :pointer))

(cffi:defcfun ("ghostty_cell_get" %cell-get) :int
  (cell :uint64) (data :int) (out :pointer))

(cffi:defcfun ("ghostty_style_default" %style-default) :void
  (style :pointer))

;; formatter.h
(cffi:defcfun ("ghostty_formatter_terminal_new" %formatter-terminal-new) :int
  (allocator :pointer) (out-formatter :pointer) (terminal :pointer)
  (options (:struct formatter-terminal-options)))

(cffi:defcfun ("ghostty_formatter_format_alloc" %formatter-format-alloc) :int
  (formatter :pointer) (allocator :pointer) (out-ptr :pointer) (out-len :pointer))

(cffi:defcfun ("ghostty_formatter_free" %formatter-free) :void
  (formatter :pointer))

;; key/encoder.h
(cffi:defcfun ("ghostty_key_encoder_new" %key-encoder-new) :int
  (allocator :pointer) (out-encoder :pointer))

(cffi:defcfun ("ghostty_key_encoder_free" %key-encoder-free) :void
  (encoder :pointer))

(cffi:defcfun ("ghostty_key_encoder_setopt" %key-encoder-setopt) :void
  (encoder :pointer) (option :int) (value :pointer))

(cffi:defcfun ("ghostty_key_encoder_setopt_from_terminal"
               %key-encoder-setopt-from-terminal) :void
  (encoder :pointer) (terminal :pointer))

(cffi:defcfun ("ghostty_key_encoder_encode" %key-encoder-encode) :int
  (encoder :pointer) (event :pointer) (out-buf :pointer) (out-buf-size :size)
  (out-len :pointer))

;; key/event.h
(cffi:defcfun ("ghostty_key_event_new" %key-event-new) :int
  (allocator :pointer) (out-event :pointer))

(cffi:defcfun ("ghostty_key_event_free" %key-event-free) :void
  (event :pointer))

(cffi:defcfun ("ghostty_key_event_set_action" %key-event-set-action) :void
  (event :pointer) (action :int))

(cffi:defcfun ("ghostty_key_event_set_key" %key-event-set-key) :void
  (event :pointer) (key key))

(cffi:defcfun ("ghostty_key_event_set_mods" %key-event-set-mods) :void
  (event :pointer) (mods :uint16))

(cffi:defcfun ("ghostty_key_event_set_consumed_mods" %key-event-set-consumed-mods) :void
  (event :pointer) (mods :uint16))

(cffi:defcfun ("ghostty_key_event_set_utf8" %key-event-set-utf8) :void
  (event :pointer) (utf8 :pointer) (len :size))

(cffi:defcfun ("ghostty_key_event_set_unshifted_codepoint"
               %key-event-set-unshifted-codepoint) :void
  (event :pointer) (codepoint :uint32))
