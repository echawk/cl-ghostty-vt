;;;; ghostty-vt.asd -- CFFI bindings to Ghostty's libghostty-vt

(defsystem "ghostty-vt"
  :description "Common Lisp CFFI bindings to libghostty-vt, Ghostty's terminal emulation library."
  :author "Ethan Hawk <ethhawk@iu.edu>"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("cffi" "cffi-libffi" "bordeaux-threads")
  :pathname "src/"
  :serial t
  :components ((:file "package")
               (:file "library")
               (:file "ffi")
               (:file "abi")
               (:file "api"))
  :in-order-to ((test-op (test-op "ghostty-vt/tests"))))

(defsystem "ghostty-vt/tests"
  :description "Tests for ghostty-vt."
  :depends-on ("ghostty-vt" "babel" "bordeaux-threads")
  :pathname "t/"
  :components ((:file "tests"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call '#:ghostty-vt/tests '#:run-tests)
               (error "ghostty-vt tests failed"))))
