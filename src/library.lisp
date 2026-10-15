;;;; library.lisp -- locate and load libghostty-vt

(in-package #:ghostty-vt.ffi)

(cffi:define-foreign-library libghostty-vt
  (:darwin (:or "libghostty-vt.dylib" "libghostty-vt.0.dylib"))
  (:windows "ghostty-vt.dll")
  (t (:or "libghostty-vt.so" "libghostty-vt.so.0")))

(defvar *library-path* nil
  "Pathname of the libghostty-vt that was loaded, or :SYSTEM when it was
found through the platform's default search path.")

(defun library-file-name ()
  (cond ((member :darwin *features*) "libghostty-vt.dylib")
        ((member :windows *features*) "ghostty-vt.dll")
        (t "libghostty-vt.so")))

(defun library-candidates ()
  "Explicit library paths to try, in order: $GHOSTTY_VT_LIBRARY (a file or a
directory containing the library), then <system>/build/lib/."
  (let ((env (uiop:getenv "GHOSTTY_VT_LIBRARY"))
        (out '()))
    (when (and env (plusp (length env)))
      (let ((dir (uiop:ensure-directory-pathname env)))
        (push (if (uiop:directory-exists-p dir)
                  (merge-pathnames (library-file-name) dir)
                  (uiop:parse-native-namestring env))
              out)))
    (push (asdf:system-relative-pathname
           "ghostty-vt" (concatenate 'string "build/lib/" (library-file-name)))
          out)
    (nreverse out)))

(defun load-libghostty-vt ()
  "Load libghostty-vt, trying LIBRARY-CANDIDATES before the system default.
Returns the loaded pathname, or :SYSTEM."
  (unless *library-path*
    (dolist (path (library-candidates))
      (let ((found (probe-file path)))
        (when found
          (if (equal (file-namestring found) (library-file-name))
              ;; Keep the library registered under its CFFI name.
              (cffi:load-foreign-library
               'libghostty-vt
               :search-path (uiop:pathname-directory-pathname found))
              (cffi:load-foreign-library (uiop:native-namestring found)))
          (return-from load-libghostty-vt (setf *library-path* found)))))
    (cffi:load-foreign-library 'libghostty-vt)
    (setf *library-path* :system))
  *library-path*)

(defvar *shim-path* nil
  "Pathname of the loaded libghostty-vt-cl shim, or NIL when it is absent
and by-value calls go through cffi-libffi.")

(defun shim-file-name ()
  (cond ((member :darwin *features*) "libghostty-vt-cl.dylib")
        ((member :windows *features*) "ghostty-vt-cl.dll")
        (t "libghostty-vt-cl.so")))

(defun load-shim ()
  "Load the optional C shim (csrc/ghostty-vt-cl.c) from $GHOSTTY_VT_SHIM_LIBRARY,
the directory libghostty-vt was loaded from, or <system>/build/lib/."
  (unless *shim-path*
    (let ((env (uiop:getenv "GHOSTTY_VT_SHIM_LIBRARY")))
      (dolist (path (remove nil
                            (list (and env (plusp (length env))
                                       (uiop:parse-native-namestring env))
                                  (and (pathnamep *library-path*)
                                       (merge-pathnames (shim-file-name) *library-path*))
                                  (asdf:system-relative-pathname
                                   "ghostty-vt"
                                   (concatenate 'string "build/lib/" (shim-file-name))))))
        (let ((found (probe-file path)))
          (when (and found
                     (ignore-errors
                      (cffi:load-foreign-library (uiop:native-namestring found))))
            (return (setf *shim-path* found)))))))
  *shim-path*)

(load-libghostty-vt)
(load-shim)
