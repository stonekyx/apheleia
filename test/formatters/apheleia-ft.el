;; -*- lexical-binding: t -*-

;; `apheleia-ft' - short for `apheleia-formatter-tests'. The functions
;; in here are not part of the public interface of Apheleia and
;; breaking changes may occur at any time.

(require 'apheleia)

(require 'cl-lib)
(require 'map)

(defvar apheleia-ft--test-dir
  (file-name-directory
   (or load-file-name buffer-file-name))
  "Directory containing this module.")

(defun apheleia-ft--get-formatters (&optional all)
  "Return list of strings naming the formatters to run.
This is determined by the environment variable FORMATTERS,
defaulting to all known formatters if the environment variable is
not set.

If ALL is non-nil, unconditionally return all formatters."
  (let ((env-var (or (getenv "FORMATTERS") "")))
    (cond
     ((or all (string-empty-p env-var))
      (mapcar #'symbol-name (map-keys apheleia-formatters)))
     (t
      (split-string env-var "[ ,]+")))))

(defun apheleia-ft--get-formatters-from-ref (ref)
  "Check out given Git REF and return `apheleia-formatters' from there.
Return an Elisp data structure, same as the `apheleia-formatters'
already in memory on the current branch."
  (let ((old-apheleia (make-temp-file "apheleia-" nil ".el"))
        (stderr-file (make-temp-file "apheleia-ft-stderr-")))
    (with-temp-file old-apheleia
      (let ((exit-status
             (call-process
              "git"
              nil (list (current-buffer) stderr-file) nil
              "show" (format "%s:apheleia.el" ref))))
        (unless (zerop exit-status)
          (with-temp-buffer
            (insert-file-contents stderr-file)
            (princ (buffer-string)))
          (error "Failed to 'git show %s:apheleia.el', got exit status %S"
                 ref exit-status))))
    (with-temp-buffer
      (call-process
       (if invocation-directory
           (expand-file-name invocation-name invocation-directory)
         invocation-name)
       nil (current-buffer) nil
       "--batch" "-l" old-apheleia "--eval" "(prin1 apheleia-formatters)")
      (goto-char (point-min))
      (read (current-buffer)))))

(defun apheleia-ft--get-formatters-for-pull-request ()
  "Return list of formatter string names that were touched in this PR.
This means their commands in `apheleia-formatters' are different
from how they appear on main, or they were added relative to
main."
  (let ((old-formatters (apheleia-ft--get-formatters-from-ref "origin/main"))
        (new-formatters apheleia-formatters)
        (touched-formatters nil))
    (map-do
     (lambda (formatter command)
       (unless (equal command (alist-get formatter old-formatters))
         (push (symbol-name formatter) touched-formatters)))
     new-formatters)
    touched-formatters))

(defun apheleia-ft-changed ()
  "Print to stdout a comma-delimited list of formatters changed in this PR."
  (princ (concat
          (string-join
           (apheleia-ft--get-formatters-for-pull-request) ",")
          "\n")))

(defun apheleia-ft--read-file (filename)
  "Return the contents of FILENAME as a string."
  (with-temp-buffer
    (insert-file-contents filename)
    (buffer-string)))

(defun apheleia-ft--write-temp-file (contents extension)
  "Write file CONTENTS string to temporary file with given EXTENSION.
Return the filename."
  (unless (or (string-prefix-p "." extension) (string-empty-p extension))
    (setq extension (concat "." extension)))
  (make-temp-file "apheleia-ft-file-" nil extension contents))

(defun apheleia-ft--input-files (formatter)
  "For given FORMATTER, return list of input files used in test cases.
These are absolute filepaths beginning with \"in.\"."
  (directory-files
   (apheleia-ft--path-join
    apheleia-ft--test-dir
    "samplecode" formatter)
   'full
   "^in\\."))

(defun apheleia-ft--path-join (component &rest components)
  "Join COMPONENT and COMPONENTS together, left to right.
Return an absolute path."
  (let ((result component))
    (while (setq component (pop components))
      (setq result (expand-file-name component result)))
    result))

(defun apheleia-ft--print-diff (lhs-name lhs rhs-name rhs)
  "Print a Git-style line-wise diff between two strings.
LHS-NAME is a human-readable name for the LHS string, same for
RHS-NAME and RHS."
  (with-temp-buffer
    (let* ((lhs-file (apheleia-ft--write-temp-file lhs lhs-name))
           (rhs-file (apheleia-ft--write-temp-file rhs rhs-name))
           (stderr-file (make-temp-file "apheleia-ft-stderr-"))
           (exit-status
            (call-process
             "git" nil (list (current-buffer) stderr-file) nil "diff"
             "--no-index" lhs-file rhs-file)))
      (unless (memq exit-status '(0 1))
        (with-temp-buffer
          (insert-file-contents stderr-file)
          (princ (buffer-string)))
        (error "Git diff exited with status %S" exit-status))
      (princ (buffer-string)))))

(defun apheleia-ft-lint ()
  "Lint general file structure for formatter tests.
This validates that necessary support files exist for every
formatter defined in apheleia.el, and that they are well-formed,
and no extraneous ones exist.

This operation is intended to be fast and simple, and does not
involve running any formatters."
  (interactive)
  (let ((formatters (mapcar #'symbol-name (map-keys apheleia-formatters)))
        (installers
         (mapcar
          (lambda (filename)
            (string-remove-suffix ".bash" filename))
          (directory-files
           (apheleia-ft--path-join
            apheleia-ft--test-dir "installers")
           nil "\\.bash$")))
        (samplecode-dirs
         (directory-files
          (apheleia-ft--path-join
           apheleia-ft--test-dir "samplecode")
          nil "^[^.]")))
    (dolist (formatter formatters)
      (unless (member formatter installers)
        (error "Missing installer script at installers/%s.bash" formatter)))
    (dolist (installer installers)
      (unless (member installer formatters)
        (error "Spurious installer script at installers/%s.bash" installer)))
    (dolist (formatter formatters)
      (unless (member formatter samplecode-dirs)
        (error "Missing sample code dir at samplecode/%s" formatter))
      (let ((in-files
             (directory-files
              (apheleia-ft--path-join
               apheleia-ft--test-dir "samplecode" formatter)
              nil "^in"))
            (out-files nil)
            (all-files
             (directory-files
              (apheleia-ft--path-join
               apheleia-ft--test-dir "samplecode" formatter)
              nil "^[^.]")))
        (unless in-files
          (error "Empty sample code dir at samplecode/%s" formatter))
        (dolist (in-file in-files)
          (let ((out-file (replace-regexp-in-string "^in" "out" in-file)))
            (unless (file-exists-p
                     (apheleia-ft--path-join
                      apheleia-ft--test-dir "samplecode" formatter out-file))
              (error "Input file %s is has no corresponding output file %s"
                     in-file out-file))
            (push out-file out-files)))
        (dolist (file all-files)
          (unless (or (member file in-files)
                      (member file out-files))
            (error "Spurious sample code file at samplecode/%s/%s"
                   formatter file)))))
    (dolist (samplecode-dir samplecode-dirs)
      (unless (member samplecode-dir formatters)
        (error
         "Spurious sample code directory at samplecode/%s"
         samplecode-dir))))
  (message "[format-test] linting passed"))

(defun apheleia-ft-test (&rest formatters)
  "Run tests for provided FORMATTERS.
Interactively, select a single formatter to test using
`completing-read'. If FORMATTERS is not provided (or,
interactively, with prefix argument), fall back to the FORMATTERS
environment variable, defaulting to all formatters."
  (interactive
   (unless (or current-prefix-arg noninteractive)
     (list (completing-read "Formatter: " (apheleia-ft--get-formatters)))))
  (dolist (formatter (or formatters (apheleia-ft--get-formatters)))
    (dolist (in-file (apheleia-ft--input-files formatter))
      (let ((extension (file-name-extension in-file))
            (in-text (apheleia-ft--read-file in-file))
            (in-temp-real-file nil)
            (in-temp-file nil)
            (out-temp-file nil)
            (command (alist-get (intern formatter) apheleia-formatters))
            (syms nil)
            (stdout-buffer nil)
            (stderr-file (make-temp-file "apheleia-ft-stderr-"))
            (default-directory temporary-file-directory)
            (exit-status nil)
            (out-file (replace-regexp-in-string
                       "/in\\([^/]+\\)" "/out\\1" in-file 'fixedcase))
            (exec-path
             (append `(,(expand-file-name
                         "scripts/formatters"
                         (file-name-directory
                          (file-truename
                           ;; Borrowed with love from Magit
                           (let ((load-suffixes '(".el")))
                             (locate-library "apheleia"))))))
                     exec-path)))
        (setq stdout-buffer (get-buffer-create
                             (format "*apheleia-ft-stdout-%S" formatter)))
        (with-current-buffer stdout-buffer
          (erase-buffer))
        (if (functionp command)
            (progn
              (setq in-temp-file (apheleia-ft--write-temp-file
                                  in-text extension))
              (with-current-buffer (find-file-noselect in-temp-file)
                (funcall command
                         :buffer (current-buffer)
                         :scratch (current-buffer)
                         :formatter formatter
                         :callback (lambda ()))
                (copy-to-buffer stdout-buffer (point-min) (point-max))))
          (progn

            (with-current-buffer stdout-buffer
              (erase-buffer))
            (mapc
             (lambda (arg)
               (when (memq arg '(file filepath input output inplace))
                 (cl-pushnew arg syms)))
             command)
            (when (or (memq 'file syms) (memq 'filepath syms))
              (setq in-temp-real-file (apheleia-ft--write-temp-file
                                       in-text extension)))
            (when (or (memq 'input syms) (memq 'inplace syms))
              (setq in-temp-file (apheleia-ft--write-temp-file
                                  in-text extension))
              (when (memq 'inplace syms)
                (setq out-temp-file in-temp-file)))
            (when (memq 'output syms)
              (setq out-temp-file (apheleia-ft--write-temp-file
                                   "" extension)))
            (setq command
                  (mapcar
                   (lambda (arg)
                     (pcase arg
                       ((or `file `filepath)
                        in-temp-real-file)
                       ((or `input `inplace)
                        in-temp-file)
                       (`output
                        out-temp-file)
                       ((guard (stringp arg))
                        arg)
                       (_ (eval arg))))
                   command))
            (setq command (delq 'npx command))
            (setq stdout-buffer (get-buffer-create
                                 (format "*apheleia-ft-stdout-%S" formatter)))
            (setq exit-status
                  (apply
                   #'call-process
                   (car command)
                   (unless (or (memq 'file syms)
                               (memq 'input syms)
                               (memq 'inplace syms))
                     in-file)
                   (list stdout-buffer stderr-file)
                   nil
                   (cdr command)))
            ;; Verify that formatter succeeded.
            (unless (zerop exit-status)
              (with-temp-buffer
                (insert-file-contents stderr-file)
                (princ (buffer-string)))
              (error
               "Formatter %s exited with status %S" formatter exit-status))))
        ;; Verify that formatter has not touched original file.
        (when in-temp-real-file
          (let ((in-text-now (apheleia-ft--read-file in-temp-real-file)))
            (unless (string= in-text in-text-now)
              (apheleia-ft--print-diff
               "original" in-text
               "updated" in-text-now)
              (error "Formatter %s modified original file in place" formatter))))
        ;; Verify that formatter formatted correctly.
        (let ((out-text
               (if (or (memq 'output syms) (memq 'inplace syms))
                   (apheleia-ft--read-file out-temp-file)
                 (with-current-buffer stdout-buffer
                   (buffer-string))))
              (expected-out-text
               (apheleia-ft--read-file out-file)))
          (unless (string= out-text expected-out-text)
            (apheleia-ft--print-diff
             "expected" expected-out-text
             "actual" out-text)
            (error "Formatter %s did not format as expected" formatter)))
        (princ (format
                "[format-test] success: formatter %s (file %s)\n"
                formatter (file-name-nondirectory in-file)))))))

(provide 'apheleia-ft)
