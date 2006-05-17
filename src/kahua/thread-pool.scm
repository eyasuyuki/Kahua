;; -*- mode: scheme; coding: utf-8-unix -*-
;;
;; kahua.thread-pool - Thread Pooling Facility
;;
;;  Copyright (c) 2006 Time Intermedia Corporation, All rights reserved.
;;  See COPYING for terms and conditions of using this software
;;
;; $Id: thread-pool.scm,v 1.1.2.1 2006/05/17 14:04:17 bizenn Exp $

(define-module kahua.thread-pool
  (use srfi-1)
  (use util.queue)
  (extend gauche.threads)
  (export <thread-pool>
	  make-thread-pool
	  add
	  wait-all
	  finish-all))
(select-module kahua.thread-pool)

(define-class <thread-pool> ()
  ((pool  :init-keyword :pool  :init-value '())
   (queue :init-keyword :queue :init-form (make-queue))
   (mutex :init-keyword :mutex :init-form (make-mutex))
   (cv    :init-keyword :cv    :init-form (make-condition-variable))))

(define (make-thread-pool num)
  (define (do-task queue mutex cv)
    (let1 t (current-thread)
      (do () ((thread-specific t))
	(mutex-lock! mutex)
	(if (queue-empty? queue)
	    (mutex-unlock! mutex cv)
	    (let1 thunk (dequeue! queue)
	      (mutex-unlock! mutex)
	      (thunk))))))
  (let* ((queue (make-queue))
	 (mutex (make-mutex))
	 (cv    (make-condition-variable))
	 (pool  (list-tabulate num (lambda _
				     (let1 t (make-thread (cut do-task queue mutex cv))
				       (thread-specific-set! t #f)
				       (thread-start! t))))))
    (make <thread-pool>
      :pool pool
      :queue queue
      :mutex mutex
      :cv cv)))

(define-method add ((tp <thread-pool>) thunk)
  (let ((queue (slot-ref tp 'queue))
	(mutex (slot-ref tp 'mutex))
	(cv    (slot-ref tp 'cv)))
    (mutex-lock! mutex)
    (enqueue! queue thunk)
    (condition-variable-signal! cv)
    (mutex-unlock! mutex)))

(define-method wait-all ((tp <thread-pool>) . maybe-interval)
  (let ((mutex (slot-ref tp 'mutex))
	(queue (slot-ref tp 'queue))
	(sleep (cute sys-nanosleep (get-optional maybe-interval 5.0e8))))
    (let loop ()
      (mutex-lock! mutex)
      (unless (queue-empty? queue)
	(mutex-unlock! mutex)
	(sleep)
	(loop)))
    (mutex-unlock! mutex)))

(define-method finish-all ((tp <thread-pool>))
  (let ((pool (slot-ref tp 'pool))
	(cv   (slot-ref tp 'cv)))
    (for-each (lambda (t) (thread-specific-set! t #t)) pool)
    (for-each (lambda (t)
		(condition-variable-broadcast! cv)
		(thread-join! t))
	      pool)))

(provide "kahua/thread-pool")
