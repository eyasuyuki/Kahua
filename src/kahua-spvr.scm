;; "Supervisor" or super server for kahua
;;
;;  Copyright (c) 2003-2004 Scheme Arts, L.L.C., All rights reserved.
;;  Copyright (c) 2003-2004 Time Intermedia Corporation, All rights reserved.
;;  See COPYING for terms and conditions of using this software
;;
;; $Id: kahua-spvr.scm,v 1.17.2.5 2006/05/26 15:25:20 bizenn Exp $

;; For clients, this server works as a receptionist of kahua system.
;; It opens a socket where initial clients will connect.
;; This server doesn't know about internals of kahua server, but
;; just dispatches it to the worker servers.
;; Eventually, this server will manage multiple worker servers for
;; load balancing or hot restarting.
;; For now, we have only one worker server, so this is just an outline
;; of what we will ultimately do.

(use gauche.charconv)
(use gauche.net)
(use gauche.threads)
(use gauche.process)
(use gauche.logger)
(use gauche.selector)
(use gauche.listener)
(use gauche.parseopt)
(use gauche.parameter)
(use gauche.mop.singleton)
(use srfi-1)
(use srfi-2)
(use srfi-11)
(use srfi-13)
(use file.util)
(use util.queue)
(use util.list)
(use util.match)
(use kahua.config)
(use kahua.gsid)
(use kahua.developer)
(use kahua.util)
(use kahua.thread-pool)

;; Eventually this should be configurable by some conf file
(define *default-worker-type* 'dummy)

(define *spvr* #f) ;; bound to supervisor object for convenience

(define *default-sigmask* #f)

(define *worker-types* '()) ;; for multi-thread version

(define-constant *TERMINATION-SIGNALS* (sys-sigset-add! (make <sys-sigset>) SIGTERM SIGINT SIGHUP))

;; Supervisor protocol
;;
;; [Session initiation]
;;
;;  A client first connect to a well known socket of the supervisor.
;;  This first request is called session-initiating request.
;;  At this point, a client wouldn't have complete GSID.  It may have
;;  state ID from the last session, but it certainly doesn't have
;;  continuation ID.
;;
;;  When the supervisor observes it, and the request is not for direct
;;  administrative request for the supervisor itself, it assigns a
;;  worker and forwards the session-initiating request to the worker.
;;  The worker will return a reply, usually accompanied by GSID.
;;  The supervisor forwards the reply to the client.
;;
;;  Afterwards, the client can figure out the worker ID encoded in GSID,
;;  and directly connects to the worker.
;;
;;  Client can optionally pass the worker type it wants to talk to,
;;  using "x-kahua-worker" header.   If such header is absent, the
;;  supervisor selects the default worker.
;;
;;  As a special case, "spvr" is given to "x-kahua-worker", the body
;;  is interpreted by the spvr process as a command.  See "supervisor
;;  commands" below.
;;
;; [Message format]
;;
;;  Request and reply both consist of two S-expressions, a header and
;;  a body.  A header is a list of two-element lists, resembles to
;;  what rfc822-header->list returns.   A body can be any valid sexpr.
;;  It is arguable whether this format is adequat or not.  Let's see.
;;
;;  In a request header, "x-kahua-sgsid" elemnt carries state GSID,
;;  and "x-kahua-cgsid" carries continuation GSID.  Other header can
;;  be freely used by the worker.  A client may send additional information
;;  in the header, and the worker should ignore the header element that
;;  it doesn't understand.
;;
;;  In a reply header, "x-kahua-sgsid" and "x-kahua-cgsid" are also
;;  used to carry GSID.  It also contains "x-kahua-status", whose value
;;  is either "OK", "ERROR", or "SPVR-ERROR".   "ERROR" indicates
;;  an error occurred in the worker, and "SPVR-ERROR" indicates an
;;  error occurred in the supervisor.  The message body of error replies
;;  contains a list of a error message string (for now).
;;

;;;=================================================================
;;; Global structure
;;;

(define-class <kahua-spvr> ()
  ((sockbase     :init-form (kahua-sockbase))
   (wtype-table  :init-form (make-hash-table 'eq?)      :getter wtype-table-of)
   (wid-table    :init-form (make-hash-table 'string=?) :getter wid-table-of)
   (wno-table    :init-form (make-hash-table 'eq?)      :getter wno-table-of)
   (selector     :init-form (make <selector>)           :getter selector-of)
   (mutex        :init-form (make-mutex)                :getter mutex-of)
   (gosh-path    :init-keyword :gosh-path) ; Absolute path of gosh, passed
                                           ; by wrapper script.
   (lib-path     :init-keyword :lib-path)  ; Path where kahua library files
                                           ; are installed.
   (keyserv      :init-value #f)           ; keyserver process
   (httpd        :init-value #f)	   ; httpd process
   ))

(define-class <kahua-worker-type> ()
  ((spvr   :init-keyword :spvr :getter spvr-of) ; back ptr to spvr
   (name   :init-keyword :name :getter name-of)	; worker type name (symbol)
   (count  :init-keyword :count
	   :getter count-of :init-value 0)	; count of running worker
   (workers :init-value #f :getter workers-of)  ; circular list of kahua-worker instances.
   (mutex  :init-form (make-mutex) :getter mutex-of)))

(define-class <kahua-worker> ()
  ((type   :getter type-of	      ; back ptr to kahua-worker-type
	   :init-keyword :type)
   (wid    :getter wid-of)	      ; worker id (string)
   (wno    :getter wno-of)	      ; Worker No.
   (process :getter process-of)	      ; worker process
   (sockaddr :getter sockaddr-of)     ; socket address
   (logger :getter logger-of)	      ; log output procedure has one arguments
   (start-time :getter start-time-of  ; timestamp
               :init-form (sys-time))
   (zombee :getter zombee?	      ; it's going to shutdown?
	   :init-form #f)
   (ping-last-time  :getter ping-last-time-of
	       :init-form (sys-time))
   (ping-deactivator :getter ping-deactivator-of
		     :init-form (lambda () (error (e) "not initialized")))
   (pinger :getter pinger-of
	   :init-form (lambda () (error (e) "not initialized")))
   (ping-responded :getter ping-responded?
		   :init-form #f)
   ;; internal
   (next-wno :allocation :class :init-value 0)
   ))

(define-class <kahua-keyserv> ()
  ((process :init-keyword :process) ;; <process>
   (id      :init-keyword :id)      ;; keyserver id
   ))

;;;=================================================================
;;; Error handling
;;;

;; Spvr should handle all "expected" exceptional cases gracefully,
;; which is indicated by throwing <spvr-exception> object.
;; If an object other than <spvr-exception> is thrown, it should be
;; a program bug.

(define-class <spvr-exception> (<error>) ())

;; A convenience function to raise <spvr-exception> or its subclasses
(define (spvr-errorf class fmt . args)
  (raise (make class :message (apply format fmt args))))

;; This exception occurs when the URI given from the client doesn't
;; correspond to any known worker type.    "404 Not found" may be
;; an appropriate response to the http client.
(define-class <spvr-unknown-worker-type> (<spvr-exception>) ())

;; This exception occurs when the URI given form the client
;; specifies a worker that is known, but is not running.
;; "503 Service unavailable" may be an appropriate response
;; to the http client.
(define-class <spvr-worker-not-running> (<spvr-exception>) ())

;; This exception occurs when the given session id is invalid
;; or may be expired.  The httpd can return "200 OK" with
;; an appropriate message.
(define-class <spvr-expired-session> (<spvr-exception>) ())

;; If errors occur before spvr service starts, we should terminate
;; spvr with appropriate error message.
(define (app-error msg . args)
  (apply format #t msg args)
  (newline)
  (exit 1))

;;;=================================================================
;;; Miscellaneous utilities
;;;

(define (send-message out header body)
  (write header out) (newline out)
  (write body out)   (newline out)
  (flush out))

(define (receive-message in)
  (let* ((header (read in))
         (body   (read in)))
    (values header body)))

(define (log-worker-action action worker)
  ((logger-of worker) action))

(define (get-worker-type header)
  (cond ((assoc "x-kahua-worker" header)
         => (lambda (p) (string->symbol (cadr p))))
        (else #f)))

;; returns a list suitable to pass run-process.  option-list
;; is appended first.
(define (script-command spvr script-name option-list)
  (list* (ref spvr 'gosh-path) "-I" (ref spvr 'lib-path)
         (build-path (ref spvr 'lib-path) script-name)
         (apply append option-list)))

(define (run-piped-cmd cmd)
  (log-format "[spvr] running ~a" cmd)
  (guard (e (else 
	     (log-format "[spvr] running ~a failed: ~a"
			 (car cmd) (kahua-error-string e #t))
	     (raise e)))
    (let1 p (apply run-process `(,@cmd :input "/dev/null" :output :pipe :sigmask ,*default-sigmask*))
      (log-format "[spvr] running ~a: pid ~a" (car cmd) (process-pid p))
      p)))

(define (circular-list->list cl)
  (let loop ((l (cons (car cl) '()))
	     (p (cdr cl)))
    (if (eq? p cl)
	(reverse! l)
	(loop (cons (car p) l) (cdr p)))))

(define (circular-list-insert-next! cl item)
  (set-cdr! cl (cons item (cdr cl)))
  cl)

(define (circular-list-remove-next! cl)
  (set-cdr! cl (cddr cl))
  cl)

(define (circular-list-remove! pred cl)
  (let1 l (circular-list->list cl)
    (apply circular-list (remove! pred l))))

(define (with-locking obj thunk)
  (with-locking-mutex (mutex-of obj) thunk))

(define (with-locking-chain thunk . args)
  (let doit ((args args))
    (if (null? args)
	(thunk)
	(with-locking (car args) (lambda () (doit (cdr args)))))))

;;;=================================================================
;;; Keyserv management
;;;

(define (start-keyserv spvr)
  (let* ((cmd (script-command spvr "kahua-keyserv.scm"
                              (cond-list
                               ((kahua-config-file)
                                => (cut list "-c" <>))
                               ((ref (kahua-config) 'user-mode)
                                => (cut list "-user" <>)))))
         (kserv (run-piped-cmd cmd))
         (kserv-id (read-line (process-output kserv))))
    (set! (ref spvr 'keyserv)
          (make <kahua-keyserv> :process kserv :id kserv-id))
    (close-input-port (process-output kserv))))

(define (stop-keyserv spvr)
  (when (ref spvr 'keyserv)
    (let1 serv (ref spvr 'keyserv)
      (set! (ref spvr 'keyserv) #f)
      (process-send-signal (ref serv 'process) SIGHUP)
      (process-wait (ref serv 'process)))))

;;;=================================================================
;;; Worker management
;;;

(define (worker-script worker-type spvr)
  (cond ((assq worker-type *worker-types*)
         => (lambda (p)
              (let ((args (get-keyword :arguments (cdr p) '()))
                    (user (ref (kahua-config) 'user-mode)))
                (script-command
                 spvr
                 "kahua-server.scm"
                 (cond-list
                  ((kahua-config-file) => (cut list "-c" <>))
                  ((ref (kahua-config) 'user-mode) => (cut list "-user" <>))
                  ((ref spvr 'keyserv) => (lambda (k) `("-k" ,(ref k 'id))))
                  (#t (cons (let1 type (symbol->string worker-type)
                              (string-append type "/" type ".kahua"))
                            args)))))))
        (else (spvr-errorf <spvr-unknown-worker-type>
                          "unknown worker type: ~a" worker-type))))

(define (load-app-servers-file)
  (let1 app-map
      (build-path (ref (instance-of <kahua-config>) 'working-directory)
                  "app-servers")
    (define (check-entries lis) ;; check vailidy of app-servers entries
      (and (list? lis)
           (every (lambda (ent)
                    (and (list? ent)
                         (symbol? (car ent))
                         (odd? (length ent))))
                  lis)))
    (cond
     ((file-exists? app-map)
      (guard (e (else
                 (log-format "[spvr] error in reading ~a" app-map)
                 #f))
        (let1 lis (call-with-input-file app-map read)
          (cond ((check-entries lis)
                 (log-format "[spvr] loaded ~a" app-map)
                 (set! *worker-types* lis)
                 #t)
                (else
                 (log-format "[spvr] malformed app-servers file: ~a" app-map)
                 #f)))))
     (else
      (log-format "app-servers file does not exist: ~a" app-map)
      #f))))

(define (%register-worker spvr type worker)
  (hash-table-put! (wid-table-of spvr) (wid-of worker) worker)
  (hash-table-put! (wno-table-of spvr) (wno-of worker) worker)
  (%add-worker! type worker))
(define (register-worker spvr type worker)
  (with-locking-chain (cut %register-worker spvr type worker) spvr type))

(define (%unregister-worker spvr type worker)
  (hash-table-delete! (wid-table-of spvr) (wid-of worker))
  (hash-table-delete! (wno-table-of spvr) (wno-of worker))
  (%remove-worker! type worker))
(define (unregister-worker spvr type worker)
  (with-locking-chain (cut %register-worker spvr type worker) spvr type))

;; start workers that are specified as "run by default"
(define (run-default-workers spvr)
  (map (lambda (w)
	 (let1 wtype (car w)
	   (run-workers spvr wtype (get-keyword :run-by-default (cdr w) 0))
	   wtype))
       *worker-types*))

;; start worker specified by worker-class
(define (%run-worker spvr type)
  (let1 w (make <kahua-worker> :type type)
    (log-worker-action "run" w)
    (%register-worker spvr type w)
    (ping-activate spvr w)
    w))

(define (%run-workers spvr type count)
  (list-tabulate count (lambda _ (%run-worker spvr type))))

(define-method run-worker ((self <kahua-spvr>) (type <kahua-worker-type>))
  (with-locking-chain (cut %run-worker self type) self type))

(define-method run-worker ((self <kahua-spvr>) (worker-type <symbol>))
  (let1 type (or (hash-table-get (wtype-table-of self) worker-type #f)
		 (make <kahua-worker-type> :spvr self :name worker-type))
    (run-worker self type)))

(define-method run-workers ((self <kahua-spvr>) (type <kahua-worker-type>) count)
  (let1 n (- count (count-of type))
    (when (> n 0)
      (with-locking-chain (cut %run-workers self type n) self type))))

(define-method run-workers ((self <kahua-spvr>) (worker-type <symbol>) count)
  (when (> count 0)
    (let1 type (or (hash-table-get (wtype-table-of self) worker-type #f)
		   (make <kahua-worker-type> :spvr self :name worker-type))
      (run-workers self type count))))

;; returns a list of workers
(define-method %list-workers ((self <kahua-spvr>))
  (sort! (hash-table-values (wno-table-of self))
	 (lambda (w1 w2)
	   (< (slot-ref w1 'wno) (slot-ref w2 'wno)))))

(define-method list-workers ((self <kahua-spvr>))
  (with-locking self (cut %list-workers self)))

(define-method %list-workers ((self <kahua-worker-type>))
  (let1 wcl (workers-of self)
    (if wcl
	(sort! (circular-list->list )
	       (lambda (w1 w2)
		 (< (slot-ref w1 'wno) (slot-ref w2 'wno))))
	'())))

(define-method list-workers ((self <kahua-worker-type>))
  (with-locking self (cut %list-workers self)))

;; collect exit status of workers that has exit.
;(define-method check-workers ((self <kahua-spvr>))
;  ;; respond check with ping
;  (let ((workers (list-workers self)))
;    (restart-workers 
;     self
;     (filter (lambda (w) (ping-timeout? w))
;	     workers)))
;  
;  ;; collect finish processes
;  (and-let* ((wq (workers-of self))
;             ((not (null? wq)))
;	     (p (process-wait-any #t))
;             (w (find (lambda (w) (eq? (worker-process-of w) p))
;                      (queue->list wq))))
;    (remove-from-queue! (cut eq? w <>) wq)
;    (if (and (kahua-auto-restart)
;	     (not (zombee? w))
;	     (> (- (sys-time) (start-time-of w)) 60))
;	;; unexpected terminated process
;	(begin
;	  (log-worker-action "restart unexpected terminated worker" w)
;	  (restart-workers self (list w)))
;	;;
;	(begin
;	  (log-worker-action "collect finished worker" w)
;	  (finish-worker w)))
;    w))
(define (check-workers . _)
  #f)					; DUMMY

;; terminate all workers
(define-method nuke-all-workers ((self <kahua-spvr>))
  (log-format "[spvr] nuke-all-workers")
  (for-each (pa$ terminate!) (hash-table-values (wtype-table-of self))))

;; terminates given workers, and starts the same number of
;; the same type workers.  Returns terminated worker id.
(define-method restart-workers ((self <kahua-spvr>) workers)
  (let1 type&ids (map (lambda (w)
                       (let ((type (type-of w))
			     (wid  (wid-of w)))
			 (log-worker-action "restart" w)
                         (terminate! w)
			 (cons type wid)))
                      workers)
    (for-each (lambda (t&i) (run-worker self (car t&i))) type&ids)
    (map cdr type&ids)))

(define-method ping-timeout? ((worker <kahua-worker>))
  (if (zombee? worker)
      #f
      (let ((d (- (sys-time) (ping-last-time-of worker))))
	(if (and (not (ping-responded? worker))
		 (> d (kahua-ping-timeout-sec)))
	    (begin
	      (log-worker-action "ping timeout" worker)
	      #t) ; timeout!	    
	    ;; not timeout
	    (begin
	      (if (and (ping-responded? worker)
		       (>= d (kahua-ping-interval-sec)))
		  ;; next ping
		  (ping-to-worker worker))
	      #f)))))

(define-method ping-activate ((spvr <kahua-spvr>) (worker <kahua-worker>))
  (let*
      (
       (sock #f)
       (in   #f)
       (out  #f)	
       (proc (lambda (fd flag)
	       (set! (ref worker 'ping-responded) #t)
	       (set! (ref worker 'ping-last-time) (sys-time))
	       (receive-message fd)
	       (ping-deactivate worker)
	       (log-worker-action "ping respond" worker)
	       ))

       (reset-sock
	(lambda ()
	  (set! sock (make-client-socket (sockaddr-of worker)))
	  (set! in   (socket-input-port sock))
	  (set! out  (socket-output-port sock))
	  )))

    (set! (ref worker 'pinger)
	  (lambda ()
	    (guard (e (else #t)) ;; do nothing, collected by check-workers
              (reset-sock)
              (set! (ref worker 'ping-responded) #f)
              (send-message out `(("x-kahua-ping" ,(wid-of worker)))
                            '())
	      (proc in #f)
	      )
	    )
	  )
    (set! (ref worker 'ping-deactivator)
	  (lambda () 
	    (and sock (socket-close sock))))
    (ping-to-worker worker)
    ))

(define-method ping-deactivate ((worker <kahua-worker>))
  ((ping-deactivator-of worker)))

(define-method ping-to-worker ((worker <kahua-worker>))
  ; (log-worker-action "ping send" worker)
  ((pinger-of worker)))

;; pick one worker that has worker-id WID.  If WID is #f, pick arbitrary one.
(define-method %find-worker ((self <kahua-spvr>) (wid <string>))
  (hash-table-get (wid-table-of self) wid #f))
(define-method find-worker ((self <kahua-spvr>) (wid <string>))
  (with-locking self (cut %find-worker self wid)))

(define-method %find-worker ((self <kahua-spvr>) (wno <integer>))
  (hash-table-get (wno-table-of self) wno #f))
(define-method find-worker ((self <kahua-spvr>) (wno <integer>))
  (with-locking self (cut %find-worker self wno)))

(define-method %find-worker ((self <kahua-spvr>) (wtype <symbol>))
  (and-let* ((wt (hash-table-get (wtype-table-of self) wtype #f)))
    (%next-worker! wt)))
(define-method find-worker ((self <kahua-spvr>) (wtype <symbol>))
  (with-locking self
    (lambda ()
      (and-let* ((wt (hash-table-get (wtype-table-of self) wtype #f)))
	(with-locking wt (cut %next-worker! wt))))))

(define-method %find-worker ((self <kahua-spvr>) _)
  ;; Fallback case, where the session-initiating request doesn't specify
  ;; the worker.  For now, we just dispatch the request to the first
  ;; worker in the queue.  Eventually we need some scheduling strategy
  (spvr-errorf <spvr-worker-not-running> "no worker specified"))

;;;=================================================================
;;; <kahua-worker-type> implementation
;;;

;;; make <kahua-worker-type> :spvr spvr :name wtype :count count
(define-method initialize ((self <kahua-worker-type>) initargs)
  (next-method)
  (let* ((spvr (spvr-of self))
	 (wid-table (wid-table-of spvr))
	 (wno-table (wno-table-of spvr)))
    (with-locking-chain
     (lambda ()
       (hash-table-put! (wtype-table-of spvr) (name-of self) self)
       (dotimes (_ (count-of self))
	 (let1 w (make <kahua-worker> :type self)
	   (%register-worker spvr self w)
	   (ping-activate spvr w))))
     spvr self)))

(define (%next-worker! wtype)
  (let1 w (and (workers-of wtype)
	       (receive (w next) (car+cdr (slot-ref wtype 'workers))
		 (slot-set! wtype 'workers next)
		 w))
    w))

(define-method next-worker! ((self <kahua-worker-type>))
  (with-locking self (cut %next-worker! self)))

(define (%add-worker! type w)
  (if (<= (count-of type) 0)
      (begin
	(slot-set! type 'count 1)
	(slot-set! type 'workers (circular-list w)))
      (begin
	(inc! (ref type 'count))
	(slot-set! type 'workers (circular-list-insert-next! (slot-ref type 'workers) w))
	(slot-set! type 'workers (cdr (slot-ref type 'workers))))))
(define-method add-worker! ((self <kahua-worker-type>) (worker <kahua-worker>))
  (with-locking self (cut %add-worker! self worker)))

(define (%remove-worker! type w)
  (let1 l (remove! (pa$ eq? w) (circular-list->list (workers-of type)))
    (if (null? l)
	(begin
	  (slot-set! type 'count 0)
	  (slot-set! type 'workers #f))
	(begin
	  (slot-set! type 'count (length l))
	  (set-cdr! (last-pair l) l)
	  (slot-set! type 'workers l)))
    ))
(define-method remove-worker! ((self <kahua-worker-type>) (worker <kahua-worker>))
  (with-locking self (cut %remove-worker! self worker)))

;;;=================================================================
;;; <kahua-worker> implementation
;;;

(define-method initialize ((self <kahua-worker>) initargs)
  (next-method)
  (let* ((wtype (type-of self))
	 (cmd   (worker-script (name-of wtype) (slot-ref wtype 'spvr)))
         (p     (run-piped-cmd cmd))
         (id    (read-line (process-output p)))
         (wno   (slot-ref self 'next-wno))
	 (log-str (format "[work] ~~A: ~A(~A - ~A)" (name-of wtype) wno id)))
    (slot-set! self 'logger (pa$ log-format log-str))
    (slot-set! self 'wid id)
    (slot-set! self 'wno wno)
    (slot-set! self 'process p)
    (slot-set! self 'sockaddr (worker-id->sockaddr id (slot-ref (spvr-of wtype) 'sockbase)))
    (inc! (ref self 'next-wno))
    ))

(define (%terminate! spvr type worker)
  (slot-set! worker 'zombee #t)
  (log-worker-action "terminate" worker)
  (%unregister-worker spvr type worker)
  (ping-deactivate worker)
  (unless (workers-of type)
    (hash-table-delete! (wtype-table-of spvr) (name-of type)))
  (let1 p (process-of worker)
    (process-send-signal p SIGTERM)
    p))

(define-method terminate! ((self <kahua-worker>))
  (if (zombee? self)
      #f
      (let* ((type (type-of self))
	     (spvr (spvr-of type)))
	  (process-wait (with-locking-chain (cut %terminate! spvr type self) spvr type)))))

(define-method terminate! ((self <kahua-worker-type>))
  (let1 spvr (spvr-of self)
    (for-each process-wait
	      (with-locking-chain
	       (lambda ()
		 (and-let* ((wcl (workers-of self)))
		   (map (pa$ %terminate! spvr self) (circular-list->list wcl))))
	       spvr self))))

;; dummy method to do something when a worker ends unexpected
(define-method unexpected-end ((self <kahua-worker>))
  (log-worker-action "unexpected finish" self))

(define-method finish-worker ((self <kahua-worker>))
  (if (not (zombee? self))
      (unexpected-end self))
  (close-input-port (process-output (process-of self))))

(define-method dispatch-to-worker ((self <kahua-worker>) header body cont)
  (let1 sock (make-client-socket (sockaddr-of self))
    (call-with-client-socket sock
      (lambda (in out)
	(send-message out header body)
	(guard (e (else
		   (cont '(("x-kahua-status" "SPVR-ERROR"))
			 (list (ref e 'message) (kahua-error-string e #t)))))
	  (receive (header body) (receive-message in)
	    (socket-shutdown sock)
	    (cont header body)))))))

;;;=================================================================
;;; Supervisor commands
;;;

(define-constant *spvr-command-table*
  (let1 t (make-hash-table 'eq?)
    (define (worker-info w)
      (list :worker-id    (wid-of w)
	    :worker-count (wno-of w)
	    :worker-type  (name-of (type-of w))
	    :worker-pid   (process-pid (process-of w))
	    :start-time   (start-time-of w)))
    (for-each (lambda (e)
		(hash-table-put! t (car e) (cdr e)))
	      `((ls       . ,(lambda _ (map worker-info (list-workers *spvr*))))
		(run      . ,(lambda args (map (lambda (type) (worker-info (run-worker *spvr* type))) args)))
		(kill     . ,(lambda args
			       (for-each
				(lambda (type-or-count)
				  (cond ((eq? type-or-count '*) 
					 (nuke-all-workers *spvr*))
					((symbol? type-or-count)
					 (terminate! (hash-table-get (wtype-table-of *spvr*) type-or-count #f)))
					((string? type-or-count)
					 (terminate! (hash-table-get (wid-table-of *spvr*) type-or-count #f)))
					((integer? type-or-count)
					 (terminate! (hash-table-get (wno-table-of *spvr*) type-or-count #f)))))
				args)
			       (map worker-info (list-workers *spvr*))))
		(types    . ,(lambda _ (map car *worker-types*)))
		(reload   . ,(lambda _ (and (load-app-servers-file)
					    (run-default-workers *spvr*))))
		(restart  . ,(lambda (args) #f))
		(shutdown . ,(lambda _
			       (log-format "[spvr] shutdown requested")
			       (sys-kill (sys-getpid) SIGTERM)))
		(help     . ,(lambda _ (hash-table-keys t)))
		(version  . ,(lambda _ (kahua-version)))))
    t))

(define (handle-spvr-command body)
  (unless (pair? body) (error "bad spvr command:" body))
  (let1 proc (hash-table-get *spvr-command-table* (car body)
			     (lambda _ (error "unknown spvr command:" body)))
    (apply proc (cdr body))))

;;;=================================================================
;;; Server Loop
;;;

;;; Common dispatching routine
(define-method handle-common ((self <kahua-spvr>) header body cont)
  (let*-values (((stat-gsid cont-gsid) (get-gsid-from-header header))
                ((stat-h stat-b) (decompose-gsid stat-gsid))
                ((cont-h cont-b) (decompose-gsid cont-gsid))
                ((wtype) (get-worker-type header)))
    (log-format "[spvr] header: ~s" header)
    (cond ((equal? wtype 'spvr)
	   ;; this is a supervisor command.
	   (cont '(("x-kahua-status" "OK")) (handle-spvr-command body)))
	  (cont-h
	   ;; we know which worker handles the request
	   (let1 w (find-worker self cont-h)
	     (unless w
	       (spvr-errorf <spvr-expired-session> "Session key expired"))
	     (dispatch-to-worker w header body cont)))
	  (else
	   ;; this is a session-initiating request.  wtype must be symbol.
	   (let1 w (find-worker self wtype)
	     (unless w
	       (if (assq wtype *worker-types*)
		   (spvr-errorf <spvr-worker-not-running>
				"Application server for ~a is not running currently."
				wtype)
		   (spvr-errorf <spvr-unknown-worker-type> "/~a" wtype)))
	     (dispatch-to-worker w header body cont))))
    ))

;;; "Kahua request" handler.  Client is kahua.cgi or kahua-admin.
(define-method handle-kahua ((self <kahua-spvr>) client-sock)
  (call-with-client-socket client-sock
    (lambda (in out)
      (guard (e
	      (#t (let ((error-log (kahua-error-string e #t)))
		    (send-message out '(("x-kahua-status" "SPVR-ERROR"))
				  (list (ref e 'message) error-log)))))
	(receive (header body) (receive-message in)
	  (handle-common self header body
			 (lambda (header body)
			   (guard (e
				   (#t (log-format "[spvr]: client closed connection")))
			     (send-message out header body))))))
      (socket-shutdown client-sock 1))))

;;
;; Actual server loop
;;
(define (run-server spvr tpool kahua-sock use-listener)
  (let ((listener (and use-listener
                       (make <listener>
                         :prompter (lambda () (display "kahua> ")))))
        )
    (when kahua-sock
      (selector-add! (selector-of spvr)
                     (socket-fd kahua-sock)
                     (lambda (fd flags)
		       (let1 client (socket-accept kahua-sock)
			 (add tpool (cut handle-kahua spvr client))))
                     '(r)))
    (when listener
      (let1 listener-handler (listener-read-handler listener)
        (set! (port-buffering (current-input-port)) :none)
        (selector-add! (selector-of spvr)
                       (current-input-port)
                       (lambda _ 
			 (listener-handler))
                       '(r)))
      (listener-show-prompt listener))

    ;; The signal mask of "root" thread is changed unexpectedly on Mac OS X 10.4.5,
    ;; maybe something wrong,  but I don't know what is wrong.
    ;; So, I restore the signal mask of "root" thread periodically.
    ;; FIXME!!
    (do () (#f)
      (sys-sigmask SIG_SETMASK *default-sigmask*)
      (selector-select (selector-of spvr) 10.0e6)
      (check-workers spvr))
    ))

;;;=================================================================
;;; Main
;;;

(define (usage)
  (print "Usage: kahua-spvr [options ...]")
  (print "Options:")
  (print "  -c, --conf-file=file  Alternative location of kahua.conf")
  (print "  -i, --interactive     Interactive REPL prompt to stdio")
  (print "  -s, --sockbase=spec   Alternative socket base")
  (print "  -l, --logfile=file    Alternative log file ('-' for stdout)")
  (print "      --user=user       User-custom setting")
  (print "  -H, --httpd=[host:]port  Accept http connection on port")
  (print "  -h, --help            Show this")
  (print "See http://www.kahua.org/ for the details")
  (exit 0))

(define (main args)
  (let-args (cdr args)
      ((conf-file "c|conf-file=s")
       (listener  "i|interactive")
       (sockbase  "s|sockbase=s")  ;; overrides conf file settings
       (logfile   "l|logfile=s")  ;; overrides conf file settings
       (user      "user=s")
       (gosh      "gosh=s")  ;; wrapper script adds this.
       (httpd     "H|httpd=s") ;; standalone httpd mode
       (help      "h|help" => usage)
       (else _ (app-error "Unknown option.  Try --help for the usage."))
       )
    (let ((lib-path (car *load-path*))) ; kahua library path.  it is
                                        ; always the first one, since the
                                        ; wrapper script adds it.
      ;; initialization
      (kahua-init conf-file :user user) ; this must come after getting lib-path
                                        ; since kahua-init adds to *load-path*
      (sys-unlink (kahua-pidpath))
      (with-output-to-file (kahua-pidpath) (lambda () (write (sys-getpid))))
      (when sockbase (set! (kahua-sockbase) sockbase))
      (cond ((equal? logfile "-") (log-open #t :prefix "~Y ~T ~P[~$]: "))
            (logfile (log-open logfile :prefix "~Y ~T ~P[~$]: "))
            (else    (log-open (kahua-logpath "kahua-spvr.log")
                               :prefix "~Y ~T ~P[~$]: ")))
      
      (let* ((sockaddr (supervisor-sockaddr (kahua-sockbase)))
             (spvr     (make <kahua-spvr>
                         :gosh-path gosh
                         :lib-path lib-path))
             (kahua-sock (make-server-socket sockaddr :reuse-addr? #t :backlog SOMAXCONN))
	     (tpool (make-thread-pool 40)) ; Oops!! hard coding.
             )
        (set! *spvr* spvr)
        ;; hack
        (when (is-a? sockaddr <sockaddr-un>)
          (sys-chmod (sockaddr-name sockaddr) #o770))
        (start-keyserv spvr)
        (log-format "[spvr] started at ~a" sockaddr)
	(let1 ret
	    (call/cc
	     (lambda (bye)
	       (define (finish-server sig)
		 (log-format "[spvr] ~a" (sys-signal-name sig))
		  (bye 0))
	       (set-signal-handler! *TERMINATION-SIGNALS* finish-server)
	       (set-signal-handler! SIGPIPE #f) ; ignore SIGPIPE
	       (set! *default-sigmask* (sys-sigmask 0 #f))
	       (guard (e (else
			  (log-format "[spvr] error in main:\n~a" 
				      (kahua-error-string e #t))
			  (report-error e)
			  (bye 70)))
		 (load-app-servers-file)
		 (run-default-workers spvr)
		 (run-server spvr tpool kahua-sock listener)
		 (bye 0))))
	  (when (is-a? sockaddr <sockaddr-un>)
	    (sys-unlink (sockaddr-name sockaddr)))
	  (nuke-all-workers spvr)
	  (wait-all tpool)
	  (finish-all tpool)
	  (stop-keyserv spvr)
	  (log-format "[spvr] exitting")
	  (sys-unlink (kahua-pidpath))
	  ret)
	))))

;; Local variables:
;; mode: scheme
;; end:
