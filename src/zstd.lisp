;;; This file is part of cl-zstd
;;; Copyright 2020 Guillaume LE VAILLANT
;;; Distributed under the GNU GPL v3 or later.
;;; See the file LICENSE for terms of use and distribution.

(in-package :zstd)


(deftype u8 () '(unsigned-byte 8))


;;;
;;; Errors
;;;

(define-condition zstd-error (simple-error)
  ())

(defmacro zstd-error (message &rest args)
  `(error 'zstd-error
          :format-control ,message
          :format-arguments (list ,@args)))

(defmacro zstd-check (form)
  (let ((code (gensym)))
    `(let ((,code ,form))
       (declare (type u64 ,code))
       (if (= (zstd-is-error ,code) 1)
           (zstd-error (zstd-get-error-name ,code))
           ,code))))


;;;
;;; Compression functions
;;;

(defun compress (context input output)
  "Read the data from the INPUT octet stream, compress it with the CONTEXT, and
write the result to the OUTPUT octet stream."
  (declare (optimize (speed 3) (space 0) (debug 0) (safety 1)))
  (let* ((input-buffer-size (zstd-c-stream-in-size))
         (input-buffer (cffi:make-shareable-byte-vector input-buffer-size))
         (output-buffer-size (zstd-c-stream-out-size))
         (output-buffer (cffi:make-shareable-byte-vector output-buffer-size)))
    (declare (type u64 input-buffer-size output-buffer-size))
    (cffi:with-foreign-objects ((in-buffer '(:struct zstd-in-buffer))
                                (out-buffer '(:struct zstd-out-buffer)))
      (cffi:with-foreign-slots ((dst size) out-buffer
                                (:struct zstd-out-buffer))
        (cffi:with-pointer-to-vector-data (ffi-output-buffer output-buffer)
          (setf dst ffi-output-buffer))
        (setf size output-buffer-size))
      (cffi:with-foreign-slots ((src size pos) in-buffer
                                (:struct zstd-in-buffer))
        (cffi:with-pointer-to-vector-data (ffi-input-buffer input-buffer)
          (setf src ffi-input-buffer))
        (labels ((read-data ()
                   (setf pos 0)
                   (setf size (read-sequence input-buffer input)))
                 (compress-and-write-data (last-chunk-p)
                   (declare (type boolean last-chunk-p))
                   (setf (cffi:foreign-slot-value out-buffer
                                                  '(:struct zstd-out-buffer)
                                                  'pos)
                         0)
                   (let* ((mode (if last-chunk-p
                                    :zstd-e-end
                                    :zstd-e-continue))
                          (remaining (zstd-check
                                      (zstd-compress-stream2 context
                                                             out-buffer
                                                             in-buffer
                                                             mode)))
                          (out-pos (cffi:foreign-slot-value
                                    out-buffer
                                    '(:struct zstd-out-buffer)
                                    'pos)))
                     (declare (type u64 remaining out-pos))
                     (write-sequence output-buffer output :end out-pos)
                     (let ((finished-p (if last-chunk-p
                                           (= remaining 0)
                                           (= pos size))))
                       (declare (type boolean finished-p))
                       (unless finished-p
                         (compress-and-write-data last-chunk-p)))))
                 (compress-data ()
                   (let ((last-chunk-p (< (read-data) input-buffer-size)))
                     (compress-and-write-data last-chunk-p)
                     (if last-chunk-p t (compress-data)))))
          (compress-data))))))

(defun initialize-context (context level)
  "Initialize the CONTEXT for the given compression LEVEL."
  (zstd-check (zstd-cctx-set-parameter context :zstd-c-compression-level level))
  (zstd-check (zstd-cctx-set-parameter context :zstd-c-checksum-flag 1))
  context)

(defun compress-stream (input output &key (level 3))
  "Read the data from the INPUT octet stream, compress it, and write the result
to the OUTPUT octet stream."
  (let ((min-level (zstd-min-c-level))
        (max-level (zstd-max-c-level)))
    (if (and (integerp level) (<= min-level level max-level))
        (let ((context (zstd-create-cctx)))
          (if (cffi:null-pointer-p context)
              (zstd-error "Failed to create compression context.")
              (unwind-protect
                   (compress (initialize-context context level) input output)
                (zstd-check (zstd-free-cctx context)))))
        (zstd-error "LEVEL must be between ~d and ~d." min-level max-level))))

(defun compress-file (input output &key (level 3))
  "Read the data from the INPUT file, compress it, and write the result to the
OUTPUT file."
  (with-open-file (input-stream input :element-type 'u8)
    (with-open-file (output-stream output :direction :output :element-type 'u8)
      (compress-stream input-stream output-stream :level level))))

(defun compress-buffer (buffer &key (start 0) end (level 3))
  "Read the data between the START and END offsets in the BUFFER, compress it,
and return the resulting octet vector."
  (let ((end (or end (length buffer))))
    (octet-streams:with-octet-output-stream (output)
      (octet-streams:with-octet-input-stream (input buffer start end)
        (compress-stream input output :level level)))))


;;;
;;; Decompression functions
;;;

(defun decompress (context input output)
  "Read the data from the INPUT octet stream, decompress it with the CONTEXT,
and write the result to the OUTPUT octet stream."
  (declare (optimize (speed 3) (space 0) (debug 0) (safety 1)))
  (let* ((input-buffer-size (zstd-d-stream-in-size))
         (input-buffer (cffi:make-shareable-byte-vector input-buffer-size))
         (output-buffer-size (zstd-d-stream-out-size))
         (output-buffer (cffi:make-shareable-byte-vector output-buffer-size)))
    (declare (type u64 input-buffer-size output-buffer-size))
    (cffi:with-foreign-objects ((in-buffer '(:struct zstd-in-buffer))
                                (out-buffer '(:struct zstd-out-buffer)))
      (cffi:with-foreign-slots ((dst size) out-buffer
                                (:struct zstd-out-buffer))
        (cffi:with-pointer-to-vector-data (ffi-output-buffer output-buffer)
          (setf dst ffi-output-buffer))
        (setf size output-buffer-size))
      (cffi:with-foreign-slots ((src size pos) in-buffer
                                (:struct zstd-in-buffer))
        (cffi:with-pointer-to-vector-data (ffi-input-buffer input-buffer)
          (setf src ffi-input-buffer))
        (labels ((read-data ()
                   (setf pos 0)
                   (setf size (read-sequence input-buffer input)))
                 (decompress-and-write-data ()
                   (setf (cffi:foreign-slot-value out-buffer
                                                  '(:struct zstd-out-buffer)
                                                  'pos)
                         0)
                   (let* ((ret (zstd-check (zstd-decompress-stream context
                                                                   out-buffer
                                                                   in-buffer)))
                          (out-pos (cffi:foreign-slot-value
                                    out-buffer
                                    '(:struct zstd-out-buffer)
                                    'pos)))
                     (declare (type u64 ret out-pos))
                     (write-sequence output-buffer output :end out-pos)
                     (if (< pos size)
                         (decompress-and-write-data)
                         ret)))
                 (decompress-data (ret)
                   (declare (type u64 ret))
                   (if (zerop (read-data))
                       (or (zerop ret) (zstd-error "Truncated stream."))
                       (decompress-data (decompress-and-write-data)))))
          (decompress-data 0))))))

(defun decompress-stream (input output)
  "Read the data from the INPUT octet stream, decompress it, and write the
result to the OUTPUT octet stream."
  (let ((context (zstd-create-dctx)))
    (if (cffi:null-pointer-p context)
        (zstd-error "Failed to create decompression context.")
        (unwind-protect
             (decompress context input output)
          (zstd-check (zstd-free-dctx context))))))

(defun decompress-file (input output)
  "Read the data from the INPUT file, decompress it, and write the result to
the OUTPUT file."
  (with-open-file (input-stream input :element-type 'u8)
    (with-open-file (output-stream output :direction :output :element-type 'u8)
      (decompress-stream input-stream output-stream))))

(defun decompress-buffer (buffer &key (start 0) end)
  "Read the data between the START and END offsets in the BUFFER, decompress
it, and return the resulting octet vector."
  (let ((end (or end (length buffer))))
    (octet-streams:with-octet-output-stream (output)
      (octet-streams:with-octet-input-stream (input buffer start end)
        (decompress-stream input output)))))
