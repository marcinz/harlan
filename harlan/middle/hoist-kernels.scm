(library
  (harlan middle hoist-kernels)
  (export hoist-kernels)
  (import (rnrs) (elegant-weapons helpers))

;; This pass is probably too big. It finds all the kernel
;; expressions, hoists them into a GPU module, replaces the old
;; expression with an apply-kernel block, and rewrites all the
;; iterator variables in the body.

(define-match hoist-kernels
  ((module ,[hoist-decl -> decl* kernel*] ...)
   `(module
      (gpu-module . ,(apply append kernel*))
      . ,decl*)))

(define-match hoist-decl
  ((fn ,name ,args ,type ,[hoist-stmt -> stmt kernel*])
   (values `(fn ,name ,args ,type ,stmt) kernel*))
  ((extern ,name ,arg-types -> ,t)
   (values `(extern ,name ,arg-types -> ,t) '())))

(define-match hoist-stmt
  ((kernel ,dims (((,x* ,t*) (,xs* ,ts*) ,dim) ...)
     ;; TODO: correctly handle free variables.
     (free-vars (,fv* ,ft*) ...)
     ;; TODO: What if this introduces free variables? What
     ;; about free variables in general?
     ,[hoist-stmt -> stmt* kernel*] ...)
   (let ((k-name (gensym 'kernel)))
     (values
      `(apply-kernel ,k-name ,xs* ...
                     ,@(map (lambda (x t) `(var ,t ,x))
                            fv* ft*))
      (cons (generate-kernel k-name x* t*
                             (map (lambda (xs) (gensym 'k_arg)) xs*)
                             ts* dim fv* ft* stmt*)
            (apply append kernel*)))))
  ((begin ,[hoist-stmt -> stmt* kernel*] ...)
   (values (make-begin stmt*) (apply append kernel*)))
  ((for (,i ,start ,end) ,[hoist-stmt -> stmt* kernel*] ...)
   (values `(for (,i ,start ,end) . ,stmt*)
           (apply append kernel*)))
  ((while ,expr ,[hoist-stmt -> stmt* kernel*] ...)
   (values `(while ,expr . ,stmt*) (apply append kernel*)))
  ((if ,test ,[hoist-stmt -> conseq ckernel*] ,[hoist-stmt -> alt akernel*])
   (values `(if ,test ,conseq ,alt) (append ckernel* akernel*)))
  (,else (values else '())))

(define-match adjust-ptr
  ((var ,t ,x)
   `(cast ,t (call (c-expr ((,t) -> ,t) adjust_header) (var ,t ,x)))))

(define generate-kernel
  (lambda (name x* t* xs* ts* dim fv* ft* stmt*)
    ;; Plan of attack: replace all vectors with renamed char *'s,
    ;; then immediate use vec_deserialize. Also, for some reason
    ;; the vector refs don't seem to be being lowered like they
    ;; should be.
    ;;
    ;; We can also let-bind vars to the cell we care about, then
    ;; replace everything with a deref. That'll be cleaner.
    `(kernel ,name ,(append (map list xs* ts*)
                            (map list fv* ft*))
             (begin
               ,@(apply
                  append
                  (map
                   (lambda (x t xs ts d)
                     `((let ,x (ptr ,t)
                            (addressof
                             (vector-ref
                              ,t ,(adjust-ptr `(var ,ts ,xs))
                              (call
                               (c-expr ((int) -> int) get_global_id)
                               (int ,d)))))))
                   x* t* xs* ts* dim))
               ,@(apply
                  append
                  (map (lambda (fv ft)
                         (match ft
                           ((vec ,t ,n)
                            `((set! (var ,ft ,fv)
                                    ,(adjust-ptr `(var ,ft ,fv)))))
                           (,else '())))
                       fv* ft*))
               . ,(replace-vec-refs stmt* x* xs* ts*)))))

(define replace-vec-refs
  (lambda (stmt* x* xs* ts*)
    (map
      (lambda (stmt)
        (fold-left 
          (lambda (stmt x xs ts)
            (let ((t (match ts
                       ((vec ,t ,n) t)
                       (,else (error 'replace-vec-refs
                                "Unknown type"
                                else)))))
                 (match stmt
                   ((var ,t ,y) (guard (eq? x y))
                    `(deref (var ,t ,x)))
                   ((,[x*] ...) x*)
                   (,x x))))
             stmt x* xs* ts*))
      stmt*)))

;; end library
)
