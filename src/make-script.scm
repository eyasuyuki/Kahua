;;; -*- mode: scheme; coding: utf-8 -*-
;;; Generate a shell script to invoke kahua operations.
;;;
;;;  Copyright (c) 2004-2007 Scheme Arts, L.L.C., All rights reserved.
;;;  Copyright (c) 2004-2007 Time Intermedia Corporation, All rights reserved.
;;;  See COPYING for terms and conditions of using this software
;;;

;; Example:
;;
;;    % gosh ./make-script.scm $(GOSH) $(libdir) kahua-admin
;;
;;    Creates a shell script kahua-admin that kicks kahua-admin.scm
;;

(define *ident* "make-script.scm")

(use file.util)
(use util.match)

(define (main args)
  (match (cdr args)
    ((gosh libdir basename) (generate gosh libdir basename))
    (else       (usage)))
  0)

(define (usage)
  (print "gosh make-script.scm $GOSH $libdir <script-basename>")
  (exit 0))

(define (generate gosh libdir basename)
  (let ((tmpname #`",|basename|.tmp"))
    (with-output-to-file tmpname
      (lambda ()
        (print "#!/bin/sh")
        (print "# This script is a part of Kahua")
        (print "# Generated by " *ident*)
        (print "# Do not edit.")
        (print "if test \"$1\" = \"--test\"; then")
        (print "  shift")
        (print "  # in-place execution.  find source tree")
        (print "  if test -r ./kahua/config.scm.in; then")
        (print "    libpath=.")
        (print "  elif test -r ../src/kahua/config.scm.in; then")
        (print "    libpath=../src")
        (print "  elif test -r ../../src/kahua/config.scm.in; then")
        (print "    libpath=../../src")
        (print "  else")
        (print "    echo \"$0: Cannot locate kahua source tree\"")
        (print "    exit 1")
        (print "  fi")
        (print "else")
        (print "  libpath=" libdir)
        (print "fi")
        (print "exec "gosh " -I${libpath} ${libpath}/"basename".scm"
               " --gosh " gosh " ${confopt}"
               " \"$@\""))
      :if-exists :supersede)
    (sys-rename tmpname basename)
    (sys-chmod basename #o555)))

;; Local variables:
;; mode: scheme
;; end:

