;;;; abi.lisp -- load-time check of struct layouts against the library
;;;;
;;;; libghostty-vt describes its own C types through ghostty_type_json().
;;;; We only need each type's total size, so instead of a JSON parser this
;;;; does a minimal scan: find "<Name>" used as an object key and read the
;;;; first "size" member inside that object (the type's own size precedes its
;;;; "fields" object).

(in-package #:ghostty-vt.ffi)

(defparameter *checked-types*
  '(("GhosttyString" (:struct ghostty-string))
    ("GhosttyColorRgb" (:struct color-rgb))
    ("GhosttyStyleColor" (:struct style-color))
    ("GhosttyStyle" (:struct style))
    ("GhosttyPoint" (:struct point))
    ("GhosttyGridRef" (:struct grid-ref))
    ("GhosttyTerminalModeConfig" (:struct mode-config))
    ("GhosttyFormatterScreenExtra" (:struct formatter-screen-extra))
    ("GhosttyFormatterTerminalExtra" (:struct formatter-terminal-extra))
    ("GhosttyFormatterTerminalOptions" (:struct formatter-terminal-options)))
  "C type name and the CFFI type that must have the same size.")

(defun skip-whitespace (string pos)
  (or (position-if-not (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return)))
                       string :start pos)
      (length string)))

(defun json-type-size (json name)
  "Size of type NAME in JSON (the ghostty_type_json() text), or NIL."
  (let ((needle (concatenate 'string "\"" name "\""))
        (start 0))
    (loop
      (let ((hit (search needle json :start2 start)))
        (unless hit (return nil))
        (let ((pos (skip-whitespace json (+ hit (length needle)))))
          (when (and (< pos (length json)) (char= (char json pos) #\:))
            (setf pos (skip-whitespace json (1+ pos)))
            (when (and (< pos (length json)) (char= (char json pos) #\{))
              (let ((size-key (search "\"size\"" json :start2 pos)))
                (when size-key
                  (let* ((colon (position #\: json :start (+ size-key 6)))
                         (num (skip-whitespace json (1+ colon))))
                    (return (values (parse-integer json :start num
                                                        :junk-allowed t))))))))
          (setf start (1+ hit)))))))

(defun abi-type-sizes ()
  "List of (c-name library-size lisp-size) for every checked type."
  (let ((json (cffi:foreign-string-to-lisp (%type-json) :encoding :utf-8)))
    (loop for (name type) in *checked-types*
          collect (list name (json-type-size json name)
                        (cffi:foreign-type-size type)))))

(defun check-abi ()
  "Warn about every struct whose CFFI size differs from libghostty-vt's.
Returns true when everything matches."
  (let ((ok t))
    (loop for (name lib lisp) in (abi-type-sizes)
          do (cond ((null lib)
                    (setf ok nil)
                    (warn "ghostty-vt: ~A is not described by ghostty_type_json(); ~
                           the library may be a different version." name))
                   ((/= lib lisp)
                    (setf ok nil)
                    (warn "ghostty-vt: ABI mismatch for ~A: library size ~D, ~
                           binding size ~D." name lib lisp))))
    ok))

(check-abi)
