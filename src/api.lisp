;;;; api.lisp -- Lisp interface over the raw bindings

(in-package #:ghostty-vt)

;;; ------------------------------------------------------------------
;;; Errors

(define-condition ghostty-error (error)
  ((code :initarg :code :reader ghostty-error-code)
   (operation :initarg :operation :reader ghostty-error-operation))
  (:report (lambda (c s)
             (format s "libghostty-vt ~A failed: ~A"
                     (ghostty-error-operation c)
                     (result-name (ghostty-error-code c))))))

(defun result-name (code)
  (case code
    (#.ffi:+success+ :success)
    (#.ffi:+out-of-memory+ :out-of-memory)
    (#.ffi:+invalid-value+ :invalid-value)
    (#.ffi:+out-of-space+ :out-of-space)
    (#.ffi:+no-value+ :no-value)
    (#.ffi:+io-error+ :io-error)
    (#.ffi:+limit-exceeded+ :limit-exceeded)
    (#.ffi:+rejected+ :rejected)
    (t code)))

(declaim (inline check))
(defun check (code operation)
  (declare (type fixnum code))
  (unless (= code ffi:+success+)
    (error 'ghostty-error :code code :operation operation))
  code)

;;; ------------------------------------------------------------------
;;; Terminal object

(defconstant +initial-grapheme-capacity+ 16)

(defstruct (terminal (:constructor %make-terminal) (:predicate terminalp))
  "A libghostty-vt terminal. Not safe for concurrent use from several
threads; distinct terminals are independent."
  (handle (cffi:null-pointer) :type cffi:foreign-pointer)
  (id 0 :type fixnum)
  (pty-write-function nil :type (or null function))
  (bell-function nil :type (or null function))
  (title-function nil :type (or null function))
  (pending-error nil)
  (busy nil)
  ;; Reused foreign scratch buffers for cell access.
  (point (cffi:null-pointer) :type cffi:foreign-pointer)
  (grid-ref (cffi:null-pointer) :type cffi:foreign-pointer)
  (style (cffi:null-pointer) :type cffi:foreign-pointer)
  (cell-buffer (cffi:null-pointer) :type cffi:foreign-pointer)
  (out (cffi:null-pointer) :type cffi:foreign-pointer)
  (graphemes (cffi:null-pointer) :type cffi:foreign-pointer)
  (grapheme-capacity +initial-grapheme-capacity+ :type fixnum)
  ;; Lazily created key encoder state.
  (key-encoder nil)
  (key-event nil))

(setf (documentation 'terminal-pty-write-function 'function)
      "Function called with an octet vector whenever the terminal answers a
query (DA, DSR, DECRQM, ...). The data must be written to the pty."
      (documentation 'terminal-bell-function 'function)
      "Function of no arguments called on BEL."
      (documentation 'terminal-title-function 'function)
      "Function called with the new title string after OSC 0/2.")

(defmethod print-object ((term terminal) stream)
  (print-unreadable-object (term stream :type t :identity t)
    (if (terminal-live-p term)
        (format stream "~Dx~D" (terminal-columns term) (terminal-rows term))
        (write-string "freed" stream))))

(defun terminal-live-p (term)
  (not (cffi:null-pointer-p (terminal-handle term))))

(declaim (inline live-handle))
(defun live-handle (term)
  (let ((h (terminal-handle term)))
    (when (cffi:null-pointer-p h)
      (error "~S has been freed." term))
    h))

;;; Registry: callbacks receive USERDATA = the terminal's integer id, which
;;; maps back to the Lisp object. No global "current terminal" state.

(defvar *registry* (make-hash-table))
(defvar *registry-lock* (bt:make-lock "ghostty-vt registry"))
(defvar *next-id* 0)

(defun register-terminal (term)
  (bt:with-lock-held (*registry-lock*)
    (let ((id (incf *next-id*)))
      (setf (terminal-id term) id
            (gethash id *registry*) term)
      id)))

(defun unregister-terminal (term)
  (bt:with-lock-held (*registry-lock*)
    (remhash (terminal-id term) *registry*)))

(defun lookup-terminal (userdata)
  (let ((id (cffi:pointer-address userdata)))
    (bt:with-lock-held (*registry-lock*)
      (values (gethash id *registry*)))))

(defun call-user (term fn &rest args)
  "Call a user callback from inside a C callback. Errors must not unwind
through C frames, so the first one is stored and re-signalled by
TERMINAL-FEED once control is back in Lisp."
  (handler-case (apply fn args)
    (serious-condition (c)
      (unless (terminal-pending-error term)
        (setf (terminal-pending-error term) c)))))

(cffi:defcallback write-pty-callback :void
    ((handle :pointer) (userdata :pointer) (data :pointer) (len :size))
  (declare (ignore handle))
  (let* ((term (lookup-terminal userdata))
         (fn (and term (terminal-pty-write-function term))))
    (when fn
      (let ((octets (make-array len :element-type '(unsigned-byte 8))))
        (dotimes (i len)
          (setf (aref octets i) (cffi:mem-aref data :uint8 i)))
        (call-user term fn octets)))))

(cffi:defcallback bell-callback :void ((handle :pointer) (userdata :pointer))
  (declare (ignore handle))
  (let* ((term (lookup-terminal userdata))
         (fn (and term (terminal-bell-function term))))
    (when fn (call-user term fn))))

(cffi:defcallback title-changed-callback :void
    ((handle :pointer) (userdata :pointer))
  (declare (ignore handle))
  (let* ((term (lookup-terminal userdata))
         (fn (and term (terminal-title-function term))))
    (when fn (call-user term fn (terminal-title term)))))

(defun make-terminal (&key (rows 24) (columns 80) on-pty-write on-bell on-title)
  "Create a terminal of ROWS x COLUMNS cells. ON-PTY-WRITE, ON-BELL and
ON-TITLE initialise the corresponding callback functions (see
TERMINAL-PTY-WRITE-FUNCTION etc., which are SETFable). Free the terminal with
TERMINAL-FREE or use WITH-TERMINAL."
  (check-type rows (integer 1 65535))
  (check-type columns (integer 1 65535))
  (let ((term (%make-terminal
               :pty-write-function (and on-pty-write (coerce on-pty-write 'function))
               :bell-function (and on-bell (coerce on-bell 'function))
               :title-function (and on-title (coerce on-title 'function)))))
    (cffi:with-foreign-object (out :pointer)
      (check (ffi:%terminal-new (cffi:null-pointer) out columns rows)
             "ghostty_terminal_new")
      (setf (terminal-handle term) (cffi:mem-ref out :pointer)))
    (handler-bind ((serious-condition (lambda (c)
                                        (declare (ignore c))
                                        (terminal-free term))))
      (setf (terminal-point term) (cffi:foreign-alloc
                                   :uint8 :count (cffi:foreign-type-size '(:struct ffi:point))
                                          :initial-element 0)
            (terminal-grid-ref term) (cffi:foreign-alloc '(:struct ffi:grid-ref))
            (terminal-style term) (cffi:foreign-alloc '(:struct ffi:style))
            (terminal-cell-buffer term) (cffi:foreign-alloc :uint64)
            (terminal-out term) (cffi:foreign-alloc :uint8 :count 16)
            (terminal-graphemes term) (cffi:foreign-alloc
                                       :uint32 :count +initial-grapheme-capacity+))
      (let ((h (terminal-handle term))
            (id (register-terminal term)))
        (flet ((set-opt (opt value)
                 (check (ffi:%terminal-set h opt value) "ghostty_terminal_set")))
          (set-opt ffi:+opt-userdata+ (cffi:make-pointer id))
          (set-opt ffi:+opt-write-pty+ (cffi:callback write-pty-callback))
          (set-opt ffi:+opt-bell+ (cffi:callback bell-callback))
          (set-opt ffi:+opt-title-changed+ (cffi:callback title-changed-callback)))))
    term))

(defun terminal-free (term)
  "Release TERM's foreign resources. Safe to call more than once."
  (unregister-terminal term)
  (flet ((free (ptr) (unless (cffi:null-pointer-p ptr) (cffi:foreign-free ptr))))
    (when (terminal-key-event term)
      (ffi:%key-event-free (terminal-key-event term))
      (setf (terminal-key-event term) nil))
    (when (terminal-key-encoder term)
      (ffi:%key-encoder-free (terminal-key-encoder term))
      (setf (terminal-key-encoder term) nil))
    (unless (cffi:null-pointer-p (terminal-handle term))
      (ffi:%terminal-free (terminal-handle term))
      (setf (terminal-handle term) (cffi:null-pointer)))
    (free (terminal-point term))
    (free (terminal-grid-ref term))
    (free (terminal-style term))
    (free (terminal-cell-buffer term))
    (free (terminal-out term))
    (free (terminal-graphemes term))
    (setf (terminal-point term) (cffi:null-pointer)
          (terminal-grid-ref term) (cffi:null-pointer)
          (terminal-style term) (cffi:null-pointer)
          (terminal-cell-buffer term) (cffi:null-pointer)
          (terminal-out term) (cffi:null-pointer)
          (terminal-graphemes term) (cffi:null-pointer)))
  nil)

(defmacro with-terminal ((var &rest args) &body body)
  "Bind VAR to (MAKE-TERMINAL ,@ARGS) for BODY and free it afterwards."
  `(let ((,var (make-terminal ,@args)))
     (unwind-protect (progn ,@body)
       (terminal-free ,var))))

;;; ------------------------------------------------------------------
;;; Input

(defun write-raw (term pointer length)
  (let ((h (live-handle term)))
    (when (terminal-busy term)
      (error "Re-entrant TERMINAL-FEED on ~S from a callback." term))
    (setf (terminal-pending-error term) nil
          (terminal-busy term) t)
    (unwind-protect (ffi:%terminal-vt-write h pointer length)
      (setf (terminal-busy term) nil))
    (let ((err (terminal-pending-error term)))
      (when err
        (setf (terminal-pending-error term) nil)
        (error err)))))

(defun terminal-feed (term data &key (start 0) end)
  "Feed DATA, a string (encoded as UTF-8) or an octet vector, from START to
END to the terminal's VT parser. Callbacks run synchronously; an error
signalled by a callback is re-signalled here after parsing the data."
  (etypecase data
    (string
     (let ((end (or end (length data))))
       (when (< start end)
         (cffi:with-foreign-string ((ptr len) data :encoding :utf-8
                                                   :null-terminated-p nil
                                                   :start start :end end)
           (write-raw term ptr len)))))
    ((simple-array (unsigned-byte 8) (*))
     (let ((end (or end (length data))))
       (assert (<= 0 start end (length data)))
       (when (< start end)
         (cffi:with-pointer-to-vector-data (ptr data)
           (write-raw term (cffi:inc-pointer ptr start) (- end start))))))
    (vector
     (terminal-feed term (coerce (subseq data start end)
                                 '(simple-array (unsigned-byte 8) (*))))))
  (values))

(defun terminal-reset (term)
  "Full terminal reset (RIS)."
  (ffi:%terminal-reset (live-handle term))
  (values))

(defun terminal-resize (term rows columns &key (cell-width-px 0) (cell-height-px 0))
  "Resize TERM to ROWS x COLUMNS. Pixel sizes are only used for size reports
and image protocols."
  (check-type rows (integer 1 65535))
  (check-type columns (integer 1 65535))
  (check (ffi:%terminal-resize (live-handle term) columns rows
                               cell-width-px cell-height-px)
         "ghostty_terminal_resize")
  (values))

;;; ------------------------------------------------------------------
;;; State queries

(defmacro define-getter (name data type &optional doc)
  `(defun ,name (term)
     ,@(when doc (list doc))
     (let ((out (terminal-out term)))
       (check (ffi:%terminal-get (live-handle term) ,data out) "ghostty_terminal_get")
       (cffi:mem-ref out ,type))))

(define-getter terminal-rows ffi:+data-rows+ :uint16 "Height in cells.")
(define-getter terminal-columns ffi:+data-cols+ :uint16 "Width in cells.")
(define-getter cursor-x ffi:+data-cursor-x+ :uint16)
(define-getter cursor-y ffi:+data-cursor-y+ :uint16)
(define-getter cursor-visible ffi:+data-cursor-visible+ :uint8)
(define-getter active-screen ffi:+data-active-screen+ :int)

(defun terminal-cursor (term)
  "Return (values ROW COLUMN VISIBLE-P), zero-based within the active area."
  (values (cursor-y term) (cursor-x term) (/= 0 (cursor-visible term))))

(defun terminal-active-screen (term)
  "Either :PRIMARY or :ALTERNATE."
  (if (zerop (active-screen term)) :primary :alternate))

(defun terminal-title (term)
  "The title set by OSC 0/2, or the empty string."
  (let ((out (terminal-out term)))
    (check (ffi:%terminal-get (live-handle term) ffi:+data-title+ out)
           "ghostty_terminal_get")
    (let ((ptr (cffi:foreign-slot-value out '(:struct ffi:ghostty-string) 'ffi:ptr))
          (len (cffi:foreign-slot-value out '(:struct ffi:ghostty-string) 'ffi:len)))
      (if (or (zerop len) (cffi:null-pointer-p ptr))
          ""
          (cffi:foreign-string-to-lisp ptr :count len :encoding :utf-8)))))

(defun terminal-mode (term mode &key ansi)
  "True if mode number MODE is set. MODE is a DEC private mode (CSI ? n h)
unless ANSI is true."
  (check-type mode (integer 0 #x7fff))
  (cffi:with-foreign-object (cfg '(:struct ffi:mode-config))
    (setf (cffi:foreign-slot-value cfg '(:struct ffi:mode-config) 'ffi:mode)
          (logior mode (if ansi #x8000 0))
          (cffi:foreign-slot-value cfg '(:struct ffi:mode-config) 'ffi:value) 0)
    (check (ffi:%terminal-get (live-handle term) ffi:+data-mode+ cfg)
           "ghostty_terminal_get")
    (/= 0 (cffi:foreign-slot-value cfg '(:struct ffi:mode-config) 'ffi:value))))

;;; ------------------------------------------------------------------
;;; Cells

(defstruct (cell (:predicate cellp))
  "Snapshot of one grid cell.
CODEPOINTS: list of code points of the grapheme cluster (NIL when empty).
WIDTH: :NARROW, :WIDE, :SPACER-TAIL (right half of a wide char) or
       :SPACER-HEAD (wrap placeholder).
FG, BG: (:DEFAULT), (:PALETTE n) or (:RGB r g b).
ATTRS: subset of :BOLD :ITALIC :FAINT :BLINK :INVERSE :INVISIBLE :STRIKE
       :OVERLINE plus one of :UNDERLINE :DOUBLE-UNDERLINE :CURLY-UNDERLINE
       :DOTTED-UNDERLINE :DASHED-UNDERLINE."
  (codepoints nil :type list)
  (width :narrow :type keyword)
  (fg '(:default) :type list)
  (bg '(:default) :type list)
  (attrs nil :type list))

(defun cell-string (cell)
  "The cell's grapheme cluster as a string (empty for blank cells)."
  (map 'string #'code-char (cell-codepoints cell)))

(defun grid-ref-at (term row col)
  "Fill TERM's scratch grid ref for active-area ROW, COL and return it."
  (let ((ref (terminal-grid-ref term)))
    (setf (cffi:foreign-slot-value ref '(:struct ffi:grid-ref) 'ffi:size)
          (cffi:foreign-type-size '(:struct ffi:grid-ref)))
    (check (if ffi:*shim-path*
               (let ((point (terminal-point term)))
                 (setf (cffi:mem-ref point :int 0) ffi:+point-tag-active+
                       (cffi:foreign-slot-value point '(:struct ffi:point) 'ffi:x) col
                       (cffi:foreign-slot-value point '(:struct ffi:point) 'ffi:y) row)
                 (ffi:%shim-terminal-grid-ref (live-handle term) point ref))
               (ffi:%terminal-grid-ref
                (live-handle term)
                (list 'ffi:tag ffi:+point-tag-active+ 'ffi:x col 'ffi:y row 'ffi:padding 0)
                ref))
           "ghostty_terminal_grid_ref")
    ref))

(defun ref-cell-value (term ref)
  (let ((cell (terminal-cell-buffer term)))
    (check (ffi:%grid-ref-cell ref cell) "ghostty_grid_ref_cell")
    (cffi:mem-ref cell :uint64)))

(defun cell-int (term cell data type)
  (let ((out (terminal-out term)))
    (check (ffi:%cell-get cell data out) "ghostty_cell_get")
    (cffi:mem-ref out type)))

(defun ref-codepoints (term ref)
  "Grapheme cluster code points of the cell at REF, as a list."
  (let ((out-len (terminal-out term)))
    (loop
      (let ((rc (ffi:%grid-ref-graphemes ref (terminal-graphemes term)
                                         (terminal-grapheme-capacity term) out-len))
            (n (cffi:mem-ref out-len :size)))
        (cond ((= rc ffi:+success+)
               (return (loop for i below n
                             collect (cffi:mem-aref (terminal-graphemes term) :uint32 i))))
              ((= rc ffi:+out-of-space+)
               (cffi:foreign-free (terminal-graphemes term))
               (setf (terminal-graphemes term) (cffi:foreign-alloc :uint32 :count n)
                     (terminal-grapheme-capacity term) n))
              (t (check rc "ghostty_grid_ref_graphemes")))))))

(defun width-keyword (wide)
  (case wide
    (#.ffi:+cell-wide-narrow+ :narrow)
    (#.ffi:+cell-wide-wide+ :wide)
    (#.ffi:+cell-wide-spacer-tail+ :spacer-tail)
    (#.ffi:+cell-wide-spacer-head+ :spacer-head)
    (t :narrow)))

(defun style-color (ptr)
  "Decode a GhosttyStyleColor at PTR."
  (let ((tag (cffi:foreign-slot-value ptr '(:struct ffi:style-color) 'ffi:tag))
        (val (cffi:foreign-slot-pointer ptr '(:struct ffi:style-color) 'ffi:value)))
    (case tag
      (#.ffi:+style-color-palette+ (list :palette (cffi:mem-ref val :uint8)))
      (#.ffi:+style-color-rgb+ (list :rgb
                                     (cffi:mem-aref val :uint8 0)
                                     (cffi:mem-aref val :uint8 1)
                                     (cffi:mem-aref val :uint8 2)))
      (t (list :default)))))

(defun style-attrs (style)
  (flet ((flag (slot) (/= 0 (cffi:foreign-slot-value style '(:struct ffi:style) slot))))
    (let ((attrs '()))
      (case (cffi:foreign-slot-value style '(:struct ffi:style) 'ffi:underline)
        (0)
        (2 (push :double-underline attrs))
        (3 (push :curly-underline attrs))
        (4 (push :dotted-underline attrs))
        (5 (push :dashed-underline attrs))
        (t (push :underline attrs)))
      (when (flag 'ffi:overline) (push :overline attrs))
      (when (flag 'ffi:strikethrough) (push :strike attrs))
      (when (flag 'ffi:invisible) (push :invisible attrs))
      (when (flag 'ffi:inverse) (push :inverse attrs))
      (when (flag 'ffi:blink) (push :blink attrs))
      (when (flag 'ffi:faint) (push :faint attrs))
      (when (flag 'ffi:italic) (push :italic attrs))
      (when (flag 'ffi:bold) (push :bold attrs))
      attrs)))

(defun terminal-cell (term row col)
  "Return a CELL describing active-area position ROW, COL (zero-based)."
  (let* ((ref (grid-ref-at term row col))
         (cell (ref-cell-value term ref))
         (width (width-keyword (cell-int term cell ffi:+cell-data-wide+ :int)))
         (content (cell-int term cell ffi:+cell-data-content-tag+ :int))
         (style (terminal-style term)))
    (setf (cffi:foreign-slot-value style '(:struct ffi:style) 'ffi:size)
          (cffi:foreign-type-size '(:struct ffi:style)))
    (check (ffi:%grid-ref-style ref style) "ghostty_grid_ref_style")
    (make-cell
     :codepoints (ref-codepoints term ref)
     :width width
     :fg (style-color (cffi:foreign-slot-pointer style '(:struct ffi:style) 'ffi:fg-color))
     :bg (case content
           ;; Background-only cells (e.g. erased with a colored SGR) carry
           ;; their color in the cell, not in a style.
           (#.ffi:+cell-content-bg-color-palette+
            (list :palette (cell-int term cell ffi:+cell-data-color-palette+ :uint8)))
           (#.ffi:+cell-content-bg-color-rgb+
            (let ((out (terminal-out term)))
              (check (ffi:%cell-get cell ffi:+cell-data-color-rgb+ out) "ghostty_cell_get")
              (list :rgb (cffi:mem-aref out :uint8 0) (cffi:mem-aref out :uint8 1)
                    (cffi:mem-aref out :uint8 2))))
           (t (style-color (cffi:foreign-slot-pointer style '(:struct ffi:style)
                                                      'ffi:bg-color))))
     :attrs (style-attrs style))))

(defun terminal-row-text (term row &key (trim t))
  "Text of active-area ROW. Wide characters appear once; blank cells are
spaces. Trailing spaces are removed when TRIM is true."
  (let ((text (with-output-to-string (s)
                (dotimes (col (terminal-columns term))
                  (let* ((ref (grid-ref-at term row col))
                         (wide (cell-int term (ref-cell-value term ref)
                                         ffi:+cell-data-wide+ :int)))
                    (unless (or (= wide ffi:+cell-wide-spacer-tail+)
                                (= wide ffi:+cell-wide-spacer-head+))
                      (let ((cps (ref-codepoints term ref)))
                        (if cps
                            (dolist (cp cps) (write-char (code-char cp) s))
                            (write-char #\Space s)))))))))
    (if trim (string-right-trim " " text) text)))

(defun terminal-screen-text (term &key (trim t) unwrap (format :plain))
  "Format the whole screen (scrollback included) with libghostty-vt's
formatter. FORMAT is :PLAIN, :VT or :HTML. TRIM drops trailing whitespace;
UNWRAP joins soft-wrapped lines."
  (let ((h (live-handle term))
        (emit (ecase format
                (:plain ffi:+formatter-format-plain+)
                (:vt ffi:+formatter-format-vt+)
                (:html ffi:+formatter-format-html+))))
    (cffi:with-foreign-objects ((fmt :pointer) (out-ptr :pointer) (out-len :size))
      (let ((options
              (list 'ffi:size (cffi:foreign-type-size '(:struct ffi:formatter-terminal-options))
                    'ffi:emit emit
                    'ffi:unwrap (if unwrap 1 0)
                    'ffi:trim (if trim 1 0)
                    'ffi:extra
                    (list 'ffi:size (cffi:foreign-type-size '(:struct ffi:formatter-terminal-extra))
                          'ffi:palette 0 'ffi:modes 0 'ffi:scrolling-region 0
                          'ffi:tabstops 0 'ffi:pwd 0 'ffi:keyboard 0
                          'ffi:screen
                          (list 'ffi:size (cffi:foreign-type-size '(:struct ffi:formatter-screen-extra))
                                'ffi:cursor 0 'ffi:style 0 'ffi:hyperlink 0
                                'ffi:protection 0 'ffi:kitty-keyboard 0 'ffi:charsets 0))
                    'ffi:selection (cffi:null-pointer))))
        (check (if ffi:*shim-path*
                   (cffi:with-foreign-object (opts '(:struct ffi:formatter-terminal-options))
                     (setf (cffi:mem-ref opts '(:struct ffi:formatter-terminal-options)) options)
                     (ffi:%shim-formatter-terminal-new (cffi:null-pointer) fmt h opts))
                   (ffi:%formatter-terminal-new (cffi:null-pointer) fmt h options))
               "ghostty_formatter_terminal_new"))
      (let ((formatter (cffi:mem-ref fmt :pointer)))
        (unwind-protect
             (progn
               (check (ffi:%formatter-format-alloc formatter (cffi:null-pointer)
                                                   out-ptr out-len)
                      "ghostty_formatter_format_alloc")
               (let ((ptr (cffi:mem-ref out-ptr :pointer))
                     (len (cffi:mem-ref out-len :size)))
                 (unwind-protect
                      (if (or (zerop len) (cffi:null-pointer-p ptr))
                          ""
                          (cffi:foreign-string-to-lisp ptr :count len :encoding :utf-8))
                   (ffi:%free (cffi:null-pointer) ptr len))))
          (ffi:%formatter-free formatter))))))

;;; ------------------------------------------------------------------
;;; Key encoding

(defparameter *named-keys*
  '((:up . :arrow-up) (:down . :arrow-down) (:left . :arrow-left)
    (:right . :arrow-right) (:home . :home) (:end . :end)
    (:page-up . :page-up) (:page-down . :page-down) (:insert . :insert)
    (:delete . :delete) (:backspace . :backspace) (:tab . :tab)
    (:enter . :enter) (:return . :enter) (:escape . :escape)
    (:f1 . :f1) (:f2 . :f2) (:f3 . :f3) (:f4 . :f4) (:f5 . :f5) (:f6 . :f6)
    (:f7 . :f7) (:f8 . :f8) (:f9 . :f9) (:f10 . :f10) (:f11 . :f11) (:f12 . :f12))
  "Short key names accepted by ENCODE-KEY, mapped to GhosttyKey names. Any
other GhosttyKey keyword (e.g. :NUMPAD-5) is accepted as is.")

(defparameter *char-keys*
  ;; (unshifted shifted key) on a US layout.
  '((#\` #\~ :backquote) (#\- #\_ :minus) (#\= #\+ :equal)
    (#\[ #\{ :bracket-left) (#\] #\} :bracket-right) (#\\ #\| :backslash)
    (#\; #\: :semicolon) (#\' #\" :quote) (#\, #\< :comma) (#\. #\> :period)
    (#\/ #\? :slash) (#\Space nil :space)
    (#\1 #\! :digit-1) (#\2 #\@ :digit-2) (#\3 #\# :digit-3) (#\4 #\$ :digit-4)
    (#\5 #\% :digit-5) (#\6 #\^ :digit-6) (#\7 #\& :digit-7) (#\8 #\* :digit-8)
    (#\9 #\( :digit-9) (#\0 #\) :digit-0)))

(defun char-key (char)
  "Return (values ghostty-key unshifted-char shifted-p) for CHAR."
  (cond ((char<= #\a char #\z)
         (values (intern (string-upcase (string char)) :keyword) char nil))
        ((char<= #\A char #\Z)
         (values (intern (string char) :keyword) (char-downcase char) t))
        (t
         (let ((entry (find char *char-keys*
                            :test (lambda (c e) (or (eql c (first e)) (eql c (second e)))))))
           (if entry
               (values (third entry) (first entry) (eql char (second entry)))
               (values :unidentified char nil))))))

(defun mods-bits (mods)
  (let ((bits 0))
    (dolist (m (if (listp mods) mods (list mods)) bits)
      (setf bits (logior bits
                         (ecase m
                           (:shift ffi:+mods-shift+)
                           ((:ctrl :control) ffi:+mods-ctrl+)
                           ((:alt :meta) ffi:+mods-alt+)
                           (:super ffi:+mods-super+)
                           (:caps-lock ffi:+mods-caps-lock+)
                           (:num-lock ffi:+mods-num-lock+)))))))

(defun ensure-key-encoder (term)
  (unless (terminal-key-encoder term)
    (cffi:with-foreign-object (out :pointer)
      (check (ffi:%key-encoder-new (cffi:null-pointer) out) "ghostty_key_encoder_new")
      (setf (terminal-key-encoder term) (cffi:mem-ref out :pointer))
      (check (ffi:%key-event-new (cffi:null-pointer) out) "ghostty_key_event_new")
      (setf (terminal-key-event term) (cffi:mem-ref out :pointer))))
  (values (terminal-key-encoder term) (terminal-key-event term)))

(defun encode-key (term key &key mods utf8 (action :press) (option-as-alt t))
  "Encode a key press for TERM's current modes (cursor-key application mode,
kitty keyboard flags, ...) and return the bytes to send to the pty as an
octet vector (possibly empty).

KEY is a character or a keyword: :UP :DOWN :LEFT :RIGHT :HOME :END :PAGE-UP
:PAGE-DOWN :INSERT :DELETE :BACKSPACE :TAB :ENTER :ESCAPE :F1..:F12, or any
GhosttyKey name such as :NUMPAD-5. MODS is a list of :SHIFT :CTRL :ALT :SUPER.
UTF8 overrides the text the key produces. ACTION is :PRESS, :REPEAT or
:RELEASE. OPTION-AS-ALT (T, NIL, :LEFT or :RIGHT) controls whether the macOS
Option key acts as Alt; it defaults to T so that :ALT behaves the same on
every platform."
  (let ((h (live-handle term))
        (bits (mods-bits mods))
        (consumed 0)
        (ghostty-key :unidentified)
        (unshifted 0)
        (text utf8))
    (etypecase key
      (character
       (case key
         ((#\Return #\Newline) (setf ghostty-key :enter))
         (#\Tab (setf ghostty-key :tab))
         ((#\Backspace #\Rubout) (setf ghostty-key :backspace))
         (#.(code-char 27) (setf ghostty-key :escape))
         (t
          (multiple-value-bind (k base shifted) (char-key key)
            (setf ghostty-key k
                  unshifted (char-code base))
            (unless text (setf text (string key)))
            (when shifted
              (setf bits (logior bits ffi:+mods-shift+)
                    consumed ffi:+mods-shift+))))))
      (keyword
       (setf ghostty-key (or (cdr (assoc key *named-keys*))
                             (and (cffi:foreign-enum-value 'ffi:key key :errorp nil) key)
                             (error "Unknown key ~S." key)))
       (when (eq ghostty-key :space)
         (setf unshifted 32)
         (unless text (setf text " ")))))
    (multiple-value-bind (encoder event) (ensure-key-encoder term)
      (ffi:%key-encoder-setopt-from-terminal encoder h)
      ;; setopt_from_terminal resets option-as-alt to false.
      (cffi:with-foreign-object (opt :int)
        (setf (cffi:mem-ref opt :int)
              (ecase option-as-alt
                ((t) ffi:+option-as-alt-true+)
                ((nil) ffi:+option-as-alt-false+)
                (:left ffi:+option-as-alt-left+)
                (:right ffi:+option-as-alt-right+)))
        (ffi:%key-encoder-setopt encoder ffi:+key-encoder-opt-macos-option-as-alt+ opt))
      (ffi:%key-event-set-action event (ecase action
                                         (:press ffi:+key-action-press+)
                                         (:repeat ffi:+key-action-repeat+)
                                         (:release ffi:+key-action-release+)))
      (ffi:%key-event-set-key event ghostty-key)
      (ffi:%key-event-set-mods event bits)
      (ffi:%key-event-set-consumed-mods event consumed)
      (ffi:%key-event-set-unshifted-codepoint event unshifted)
      (flet ((encode ()
               (cffi:with-foreign-object (out-len :size)
                 (let ((size 64))
                   (loop
                     (cffi:with-foreign-object (buf :uint8 size)
                       (let ((rc (ffi:%key-encoder-encode encoder event buf size out-len)))
                         (cond ((= rc ffi:+success+)
                                (let* ((n (cffi:mem-ref out-len :size))
                                       (v (make-array n :element-type '(unsigned-byte 8))))
                                  (dotimes (i n) (setf (aref v i) (cffi:mem-aref buf :uint8 i)))
                                  (return v)))
                               ((= rc ffi:+out-of-space+)
                                (setf size (max (1+ size) (cffi:mem-ref out-len :size))))
                               (t (check rc "ghostty_key_encoder_encode"))))))))))
        (if (and text (plusp (length text)))
            (cffi:with-foreign-string ((ptr len) text :encoding :utf-8 :null-terminated-p nil)
              (ffi:%key-event-set-utf8 event ptr len)
              (unwind-protect (encode)
                (ffi:%key-event-set-utf8 event (cffi:null-pointer) 0)))
            (progn
              (ffi:%key-event-set-utf8 event (cffi:null-pointer) 0)
              (encode)))))))
