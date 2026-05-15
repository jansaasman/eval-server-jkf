
;; evalserver
;; 
;; mlisp -batch -e '(progn (load (compile-file "es")) (user::start-server))'
;; 
;;
;; options:
;;   form  - string to read and evaluate.  optional.  If not given
;;           we assume you want to evaluate nil
;;   compile - if given the value of "yes" then the form is compiled
;;		and funcalled not evaled
;;   package - string naming the package for reading the form to evaluate
;;            and print the result to string.  This selection is sticky
;;            and will be used for subseqent calls.
;;   key - key to match against key used when the server is started
;;         if no match then the eval isn't done
;;   timeout  - value is like "30" meaning 30 seconds.  after timeout
;;         expires you'll get a success of "error" and a result
;;         saying expression timed out.
;;   reset  - if value is "yes" it will first kill of any other running
;;           evalserver processes which will return success of "error"
;;   log-file - name of file to which the interaction with lisp is written
;;   lock-file - name of file to which the pid of the evalserver is written
;;
;; return is assoc list
;;  success -  "ok" or "error"
;;  result  - result of evalution (if "ok") or error message (if "error")
;;  backtrace - zoom of the stack if error during evaluation
;;  output - what as printed to standard output
;;  error-output - what is printed to standard error
;;
;;  versions:
;;    1.0 - initial
;;    1.1 - limit backtrace to 50 items
;;    1.2 - turn *read-eval* off when reading for safety
;;    1.3 - reuse-address and add :lock-file arg


(defpackage :es (:use :common-lisp :excl))


(in-package :es)

(eval-when (compile load eval) (require :st-json))


(defparameter *evalserver-version* "1.3")

(defvar *key* nil)
(defvar *log-file* nil)
(defvar *log-stream* nil)

(defvar *my-readtable* (copy-readtable))
(defvar *my-package*  (find-package "common-lisp-user"))
(defvar *lock-file* nil)

(defmacro with-my-state (&body body)
  `(let ((*readtable* *my-readtable*)
         (*package*   *my-package*))
     ,@body))

(defmacro assoc-value (key alist)
  `(cdr (assoc ,key ,alist :test #'equal)))


(defun user::start-server (&key (port 2233) 
                                (key "") 
                                (standalone nil)
                                (detach nil)
                                (log-file nil)
                                (lock-file nil)
                                )
  
  (setq *log-file* log-file)

  (if* *log-file*
     then (setq *log-stream*
            (open *log-file*
                  :direction :output
                  :if-exists :append
                  :if-does-not-exist :create
                  :class 'excl::line-buffered-file-stream
                  ))
          ;; this should have happened automatically.. not sure
          ;; why I have to do this explicitly
          excl::(with-stream-class (line-buffered-mixin es::*log-stream*) 
                  (setf (sm control-out es::*log-stream*) 
                    *line-buffered-control-out-table*))
          
          (format *log-stream* "~%Starting Eval Server on port ~s~%"
                  port)
          (force-output *log-stream*)
          )

  (setq *lock-file* lock-file)
  
  (if* lock-file
     then (ignore-errors
           (progn (kill-old-evalserver lock-file)
                  (delete-file lock-file))))
              
  (let (psock)
    (unwind-protect
        (handler-case 
            (progn 
              (setq psock (socket:make-socket :connect :passive :local-port port :reuse-address t))
              
              (setq *key* key)
              (if* detach
                 then (let ((pid (excl.osi:fork)))
                        (if* (zerop pid)
                           then ; child
                                (format t "listener pid ~d listening on port ~s~%"
                                        (excl.osi:getpid)
                                        (socket:local-port psock))
                                (excl.osi:detach-from-terminal)
                                (excl.osi:setpgid 0 0)
                                (if* lock-file
                                   then (create-lock-file lock-file))
                                (process-commands psock)
                           else (exit 0 :quiet t)))
                 else (format t "listener listening on port ~s~%"
                              (socket:local-port psock))
                      (if* lock-file
                         then (create-lock-file lock-file))
                      (process-commands psock)))
    
          (error (c)
      
            (if* standalone
               then (format *error-output*
                            "Attempting to start server on port ~d failed with error ~a" port c)
                    (exit 1 :no-unwind t) ; fail
               else (error "failed to start with error ~a" c))))
      ;; cleanup
      (close psock))))

(defparameter *es-processes* nil)
                   
(defun process-commands (passive-sock)
  (loop 
    
    (let ((sock (socket:accept-connection passive-sock)))
      (push (mp:process-run-function "evaluator"
              #'(lambda ()
                  (unwind-protect
                      (multiple-value-bind (ans kind) (process-one-command sock)
                        (format sock "~a~%" (convert-to-kind ans kind))
                        (force-output sock))
                    ;; cleanup
                    (setq *es-processes* 
                      (delete mp:*current-process* *es-processes*))
                    (close sock)
                    )))
            *es-processes*))))

;;
;;  input is
;;  for lisp:
;;   (:key  "sdsdfasf" :form  "(+ 3 4)")
;; or 
;;   (("key" . "aasdfa") ("form" . "(+ 3 4)"))
;;
;; or json:
;;   {"key" : "sdfasdf", "form" : "(+ 3 4)"}


;; return in an alist for lisp and a json object for json
;; the key's are
;;   "success" 
;;     value is "ok" or "error"
;;   "result"
;;      value is string from printing answer (if success is "ok")
;;      value is error message if success is "error"
;;   "backtrace"
;;     string of a zoom if success is "error" and the form was 
;;     read and evaluated
;;   "exit"
;;     exit evalserver
;;



(defun process-one-command (sock)
  (multiple-value-bind (command kind) (read-one-command sock)
    (values (if* (and (consp command) (eq :error (car command)))
               then `(("success" . "error") ("result" . ,(cadr command)))
               else (catch 'input-failure
                      (eval-one-command 
                       (handler-case
                           (convert-to-alist command kind)
                         (error (c)
                           (throw 'input-failure
                             `(("success" . "error")
                               ("result" . ,(format nil "form was not in plist or alist form, error signalled: ~a" c)))))))))
            kind)))
                                                             
            
    

    
(defun read-one-command (sock)
  ;; if things go well returns two values
  ;;   1. input form (either lisp expression or json object)
  ;;   2. :lisp or :json
  ;; if things go bad return list:
  ;;   1. (:error "error message")
  ;;   2. nil
  
  (let (line
        (eof-token (gensym "eof"))
        (inc-token (gensym "inc")) ; incomplete input
        (kind :lisp)
        )

    (values (progn
              ;; find out the form: lisp or json
              (setq kind 
                (loop
                  (let ((this (read-line sock nil eof-token)))
                    (if* (eq this eof-token)
                       then (return-from read-one-command '(:error "no input"))
                       else (setq line (concatenate 'simple-string
                                         line this))))
                  (let ((fnb (find-first-non-blank line)))
                    (case fnb
                      (#\( (return :lisp))
                      (#\{ (return :json))
                      ((nil) ; loop around
                       )
                      (t (return-from read-one-command '(:error "input syntax error")))))))
              
              ;; try parsing the input
              (loop
                (case kind
                  (:lisp
                   (let ((form 
                          (handler-case
                              (let ((*read-eval* nil))
                                (read-from-string line))
                            (error (c)
                              (declare (ignore c))
                              inc-token))))
                     (if* (not (eq form inc-token))
                        then 
                             (return form))))
                  
                  (:json
                   (let ((form (handler-case
                                   (st-json:read-json-from-string line)
                                 (error (c)
                                   c
                                   inc-token))))
                     (if* (not (eq form inc-token))
                        then (return form)))))
                
                ;; read next chunk
                (let ((this (read-line sock nil eof-token)))
                  (if* (eq this eof-token)
                     then (return-from read-one-command '(:error "incomplete expression on input"))
                     else (setq line (concatenate 'simple-string line this))))))
            kind)))




(defun find-first-non-blank (string)
  (dotimes (i (length string) nil)
    (case (schar string i)
      ((#\space #\tab #\return #\linefeed) nil) ; skip
      (t (return (schar string i))))))
                             
                                                   
(defun eval-one-command (alist)
  (let ((key (assoc-value "key" alist))
        (form (or (assoc-value "form" alist) "nil"))
        (package (assoc-value "package" alist))
        (compile (assoc-value "compile" alist))
        (timeout (assoc-value "timeout" alist))
        (reset   (assoc-value "reset"   alist))
        (exit    (assoc-value "exit" alist))
        )
    (if* (and key *key*)
       then (if* (not (equal key *key*))
               then (return-from eval-one-command
                      `(("success" . "error") ("result" . "incorrect key given")))))

    (if* exit 
       then (kill-lock-file)
            (exit 0 :no-unwind t))
    
    (if* (equal reset "yes")
       then (dolist (proc *es-processes*)
              (if* (not (eq mp:*current-process* proc))
                 then (mp:process-interrupt proc #'error
                                            "process reset due to command"))))
                        
                
    (if* timeout
       then (if* (numberp timeout)
               then nil
             elseif (stringp timeout)
               then (setq timeout (ignore-errors (parse-integer timeout)))))
            
    
    (if* package 
       then (let ((new-package (find-package package)))
              (if* (null new-package)
                 then 
                      (return-from eval-one-command
                        `(("success" . "error")
                          ("result" . ,(format nil "requested package ~s does not exist" package))))
                 else (setq *my-package* new-package))))
            

    (let* ((so-stream (make-string-output-stream))
           (eo-stream (make-string-output-stream))
           (*standard-output* 
            (if* *log-stream*
               then (make-broadcast-stream
                     so-stream
                     *log-stream*)
               else so-stream))
           (*error-output*  
            (if* *log-stream*
               then (make-broadcast-stream
                     eo-stream
                     *log-stream*)
               else eo-stream))
           (*system-messages* *error-output*))

      (handler-bind ((error #'(lambda (e)
                                (return-from eval-one-command
                                  `(("success" . "error")
                                    ("result" . 
                                              ,(format nil "evaluation resulted in error: ~a" e))
                                    ("backtrace" . ,(do-backtrace)))))))
        (with-my-state
            (mp::with-timeout ((or timeout 99999999)
                               (error "evaluation timed out after ~s seconds"
                                      timeout))
              (let* ((to-eval (read-from-string form))
                     (ignore (if* *log-stream*
                                then (format *log-stream* "~%--- eval ~s ---~%"
                                             to-eval)
                                     (force-output *log-stream*)))

                     (ans (if* (equal compile "yes")
                             then (funcall (compile nil
                                                    `(lambda () ,to-eval)))
                             else (eval to-eval))))
                
                (declare (ignore ignore))
                
                (if* *log-stream*
                   then (format *log-stream* "~a~%" ans))
                        
                (force-output *standard-output*)
                (force-output *error-output*)
                (force-output *log-stream*)
        
                `(("success" . "ok")
                  ("result" . ,(with-my-state (write-to-string ans)))
                  ("output" . ,(get-output-stream-string so-stream))
                  ("error-output" .  ,(get-output-stream-string eo-stream)
                                  )))))))))
                    
                    
            
(defun convert-to-alist (form kind)
  (case kind
    (:lisp
     (if* (atom (car form))
        then ;; plist form
             (do ((plist form (cddr plist))
                  (res))
                 ((null plist)
                  res)
               (push (cons (string (car plist))
                           (if* (numberp (cadr plist))
                              then (write-to-string (cadr plist))
                              else (string (cadr  plist))))
                     res))
        else (do ((alist form (cdr alist))
                  (res))
                 ((null alist)
                  res)
               (push (cons (string (caar alist))
                           (if* (numberp (cdar alist))
                              then (write-to-string (cdar alist))
                              else (string (cdar alist))))
                     res))))
    (:json
     (do ((alist (st-json::jso-alist form) (cdr alist))
          (res))
         ((null alist)
          res)
       (push (cons (string (caar alist))
                   (string (cdar alist)))
             res)))))
                 	
             
(defun convert-to-kind (alist kind)
  (case kind
    (:json (st-json::write-json-to-string (st-json::make-jso :alist alist)))
    ;; default to lisp if we can't determine the kind due to bogus input
    (t  (write-to-string alist))))

(defun do-backtrace ()
  (let* ((s (make-string-output-stream))
         (*terminal-io* s)
         (*standard-output* s))
    (apply #'tpl:do-command "zoom" :from-read-eval-print-loop nil
           '(:count 50 :all t))
    (get-output-stream-string s)))

(defun create-lock-file (filename)
  (setf (file-contents filename) (write-to-string (excl.osi:getpid))))

(defun kill-old-evalserver (filename)
  (excl.osi:kill (let ((*read-eval* nil))
                   (read-from-string (file-contents filename)))
                 9)
  (sleep 2)
  )

(defun kill-lock-file ()
  (if* *lock-file*
     then (ignore-errors (delete-file *lock-file*))))

;; client

(defun call-evalserver (form host port &key key)
  (let ((sock (socket:make-socket :remote-host host :remote-port port))
        (expr `(:key ,(or key "") :form ,(write-to-string form))))
    (unwind-protect
        (progn
          (format sock "~s~%" expr)
          (force-output sock)
          (socket:shutdown sock :direction :output)
          (let ((ans (read sock)))
            (let ((success (cdr (assoc "success" ans :test #'equal))))
              (if* (equal success "ok")
                 then (values (read-from-string (cdr (assoc "result" ans :test #'equal))))
                 else (format t "Error occured~%message: ~a~%"
                              (cdr (assoc "result" ans :test #'equal)))
                      (let ((bt (cdr (assoc "backtrace" ans :test #'equal))))
                        (if* bt 
                           then (format t "Backtrace:~%~a~%" bt)))))))
      ;; cleanup
      (close sock))))
                          
                          
    
  
