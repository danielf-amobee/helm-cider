;;; helm-cider.el --- Helm interface to CIDER        -*- lexical-binding: t; -*-

;; Copyright (C) 2016 Tianxiang Xiong

;; Author: Tianxiang Xiong <tianxiang.xiong@gmail.com>
;; Package-Requires: ((cider "0.12") (cl-lib "0.5") (helm-core "1.9") (seq "1.0"))
;; Keywords: tools, convenience
;; URL: https://github.com/clojure-emacs/helm-cider

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Helm interface to CIDER.

;; For more about Helm, see: https://github.com/emacs-helm/helm
;; For more about CIDER, see: https://github.com/clojure-emacs/cider

;;; Code:

(require 'cider)
(require 'cl-lib)
(require 'helm-lib)
(require 'helm-multi-match)
(require 'helm-source)
(require 'seq)


;;;; Customize
(defgroup helm-cider nil
  "Helm interface to CIDER."
  :prefix "helm-cider-"
  :group 'cider)

;;;;; Apropos

(defgroup helm-cider-apropos nil
  "Helm CIDER apropos"
  :prefix "helm-cider-apropos-"
  :group 'helm-cider)

(defcustom helm-cider-apropos-excluded-ns '("cider.*")
  "List of namespaces to exclude from CIDER apropos.

Namespace globs (e.g. \"cider.*\" for all CIDER-specific
namespaces) are accepted.

By default, CIDER-specific namespaces (those used by CIDER
itself, e.g. \"cider.nrepl.middleware.apropos\") are excluded."
  :group 'helm-cider-apropos
  :type '(repeat string))

(defcustom helm-cider-apropos-follow nil
  "If true, enable `helm-follow-mode' for CIDER apropos
sources."
  :group 'helm-cider-apropos
  :type 'boolean)

(defcustom helm-cider-apropos-ns-actions
  '(("Search in namespace" . helm-cider-apropos-symbol)
    ("Search in namespace with docs" . helm-cider-apropos-symbol-doc)
    ("Find definition" . (lambda (ns)
                           (cider-find-ns nil ns)))
    ("Set REPL namespace" . cider-repl-set-ns))
  "Actions for Helm CIDER apropos namespaces."
  :group 'helm-cider-apropos
  :type '(alist :key-type string :value-type function))

(defcustom helm-cider-apropos-actions
  '(("CiderDoc" . cider-doc-lookup)
    ("Find definition" . (lambda (candidate)
                           (cider-find-var nil candidate)))
    ("Find on Grimoire" . cider-grimoire-lookup))
  "Actions for Helm CIDER apropos symbols."
  :group 'helm-cider-apropos
  :type '(alist :key-type string :value-type function))

(defcustom helm-cider-apropos-ns-key "C-c n"
  "String representation of key sequence for executing
`helm-cider-apropos-ns'.

This is intended to be added to the keymap for
`helm-cider-apropos'."
  :group 'helm-cider-apropos
  :type 'string)

(defcustom helm-cider-apropos-symbol-doc-key "S-<return>"
  "String representation of key sequence of executing
`helm-cider-apropos-symbol-doc'.

This is intended to be added to the keymap for
`helm-cider-apropos-ns.'"
  :group 'helm-cider-apropos
  :type 'string)


;;;; Utilities

(defun helm-cider--regexp-symbol (string)
  "Create a regexp that matches STRING as a symbol."
  (concat "\\_<" (regexp-quote (or string "")) "\\_>"))

(defun helm-cider--symbol-name (qualified-name)
  "Get the name porition of the fully qualified symbol name
QUALIFIED-NAME (e.g. \"reduce\" for \"clojure.core/reduce\")."
  (cadr (split-string qualified-name "/")))

(defun helm-cider--symbol-ns (qualified-name)
  "Get the namespace portion of the fully qualified symbol name
QUALIFIED-NAME (e.g. \"clojure.core\" for
\"clojure.core/reduce\")."
  (car (split-string qualified-name "/")))

(defun helm-cider--symbol-face (type)
  "Face for symbol of TYPE.

TYPE values include \"function\", \"macro\", etc."
  (pcase type
    ("function" 'font-lock-function-name-face)
    ("macro" 'font-lock-keyword-face)
    ("variable" 'font-lock-variable-name-face)))

(defun helm-cider--make-sort-sources-fn (&optional descending)
  "Sort Helm sources by name in ascending order.

If DESCENDING is true, sort in descending order."
  (let ((fn (if descending #'string> #'string<)))
    (lambda (s1 s2)
      (funcall fn (assoc-default 'name s1) (assoc-default 'name s2)))))


;;;; Apropos

(defun helm-cider--excluded-ns-p (ns &optional excluded-ns)
  "Return true when namespace NS matches one of EXCLUDED-NS.

EXCLUDED-NS is a list of namespaces (e.g. \"clojure.core\")
and/or namespace globs (e.g. \"cider.*\"). If not provided,
`helm-cider-apropos-excluded-ns' is used.

NS matches a string equal to itself, or a string ending in \"*\"
that is a prefix of NS, excluding the \"*\"."
  (catch 'excluded
    (dolist (ex (or excluded-ns
                    helm-cider-apropos-excluded-ns))
      (when (or (and (string-suffix-p "*" ex)
                     (string-prefix-p (substring ex 0 (1- (length ex))) ns))
                (string= ns ex))
        (throw 'excluded t)))))

(defun helm-cider--apropos-dicts (&optional excluded-ns)
  "List of CIDER apropos results (nREPL dicts).

Symbols in namespaces in EXCLUDED-NS are excluded.  If not
provided, `helm-cider-apropos-excluded-ns' is used."
  (cl-loop with excluded-ns = (or excluded-ns helm-cider-apropos-excluded-ns)
           for dict in (cider-sync-request:apropos "")
           unless (helm-cider--excluded-ns-p (helm-cider--symbol-ns (nrepl-dict-get dict "name"))
                                             excluded-ns)
           collect dict))

(defun helm-cider--apropos-hashtable (dicts)
  "Build a hash table from CIDER apropos results (DICTS).

Keys are namespaces and values are lists of results (nREPL
dict objects)."
  (let ((ht (make-hash-table :test 'equal)))
    (dolist (dict dicts)
      (let ((ns (helm-cider--symbol-ns (nrepl-dict-get dict "name"))))
        (puthash ns (cons dict (gethash ns ht)) ht)))
    ht))

(defun helm-cider--apropos-candidate (dict)
  "Create a Helm CIDER apropos candidate.

DICT is an nREPL dict."
  (nrepl-dbind-response dict (name type)
    (cons (propertize (helm-cider--symbol-name name)
                      'face (helm-cider--symbol-face type))
          name)))

(defun helm-cider--apropos-doc-candidate (dict)
  "Create a Helm CIDER apropos doc candidate.

DICT is an nREPL dict."
  (nrepl-dbind-response dict (name type doc)
    (with-temp-buffer
      ;; Name
      (insert (propertize name 'face (helm-cider--symbol-face type)))
      (insert "\n")
      ;; Doc
      (let ((beg (point)))
        (insert doc "\n")
        (fill-region beg (point-max)))
      ;; Candidate
      (cons (buffer-string) name))))

(defun helm-cider--apropos-source (ns &optional dicts doc follow)
  "Helm source for namespace NS (e.g. \"clojure.core\").

DICTS is a list of CIDER apropos results (nREPL dicts) for
NS. If not provided, it is obtained with
`cider-sync-request:apropos'.

If DOC is true, include symbol documentation in candidates.

If FOLLOW is true, use `helm-follow-mode' for source."
  (helm-build-sync-source ns
    :action helm-cider-apropos-actions
    :candidate-transformer (lambda (candidates)
                             (seq-sort (lambda (a b)
                                         (string< (cdr a) (cdr b)))
                                       candidates))
    :candidates (let ((fn (if doc
                              #'helm-cider--apropos-doc-candidate
                            #'helm-cider--apropos-candidate)))
                  (mapcar fn (or dicts
                                 (cider-sync-request:apropos "" ns))))
    :follow (when follow 1)
    :multiline doc
    :nomark t
    :persistent-action #'cider-doc-lookup
    :volatile t))

(defun helm-cider--apropos-sources (&optional excluded-ns doc)
  "A list of Helm sources for CIDER apropos.

Each source is the set of symbols in a namespace.  Namespaces in
EXCLUDED-NS are excluded.  If not provided,
`helm-cider-apropos-excluded-ns' is used.

If DOC is true, include symbol documentation in candidates."
  (cl-loop with ht = (helm-cider--apropos-hashtable
                      (helm-cider--apropos-dicts excluded-ns))
           for ns being the hash-keys in ht using (hash-value dicts)
           collect (helm-cider--apropos-source ns dicts doc helm-cider-apropos-follow)
           into sources
           finally (return (sort sources (helm-cider--make-sort-sources-fn)))))

(defun helm-cider--apropos-ns-source (&optional excluded-ns)
  "Helm source of namespaces.

Namespaces in EXCLUDED-NS are excluded.  If not provided,
`helm-cider-apropos-excluded-ns' is used."
  (helm-build-sync-source "Clojure Namespaces"
    :action helm-cider-apropos-ns-actions
    :candidates (cl-loop for ns in (cider-sync-request:ns-list)
                         unless (helm-cider--excluded-ns-p ns excluded-ns)
                         collect (cider-propertize ns 'ns) into all
                         finally (return (sort all #'string<)))
    :nomark t
    :volatile t))

(defun helm-cider--apropos-map (&optional keymap)
  "Return a keymap for use with Helm CIDER apropos.

If KEYMAP is provided, make a copy of it to modify. Else, make a
copy of `helm-map'."
  (let ((keymap (copy-keymap (or keymap helm-map))))
    ;; Select namespace
    (define-key keymap (kbd helm-cider-apropos-ns-key)
      (lambda ()
        (interactive)
        (helm-exit-and-execute-action (lambda (candidate)
                                        (helm-cider-apropos-ns candidate)))))
    ;; Apropos with docs
    (dolist (key (cl-mapcan (lambda (command)
                              (where-is-internal command cider-mode-map))
                            '(cider-apropos-documentation
                              cider-apropos-documentation-select)))
      (define-key keymap key
        (lambda ()
          (interactive)
          (helm-exit-and-execute-action
           (lambda (candidate)
             (with-helm-after-update-hook
               (with-helm-buffer
                 (helm-preselect (helm-cider--symbol-name candidate)
                                 (helm-cider--symbol-ns candidate)))
               (recenter 1))
             (helm-cider-apropos-symbol-doc))))))
    ;; Apropos
    (dolist (key (cl-mapcan (lambda (command)
                              (where-is-internal command cider-mode-map))
                            '(cider-apropos
                              cider-apropos-select)))
      (define-key keymap key
        (lambda ()
          (interactive)
          (helm-exit-and-execute-action
           (lambda (candidate)
             (with-helm-after-update-hook
               (with-helm-buffer
                 (helm-preselect (helm-cider--symbol-name candidate)
                                 (helm-cider--symbol-ns candidate))
                 (recenter 1)))
             (helm-cider-apropos-symbol))))))
    keymap))


(defun helm-cider--apropos-ns-map (&optional keymap)
  "Return a keymap for use with Helm CIDER apropos namespaces.

If KEYMAP is provided, make a copy of it to modify. Else, make a
copy of `helm-map'."
  (let ((keymap (copy-keymap (or keymap helm-map))))
    (define-key keymap (kbd helm-cider-apropos-symbol-doc-key)
      (lambda ()
        (interactive)
        (helm-exit-and-execute-action (lambda (candidate)
                                        (helm-cider-apropos-symbol-doc candidate)))))
    keymap))


;;;; Autoloads

;;;;; Apropos

;;;###autoload
(defun helm-cider-apropos-symbol (&optional source doc)
  "Choose Clojure symbols across namespaces.

Each Helm source is a Clojure namespace, and candidates are
symbols in the namespace.

If SOURCE is provided, puts the selection line on the first
candidate of SOURCE.

If DOC is true, include symbol documentation in candidate.

Set `helm-cider-apropos-follow' to true to turn on
`helm-follow-mode' for all sources. This is useful for quickly
browsing documentation."
  (interactive)
  (cider-ensure-connected)
  (when source
    (with-helm-after-update-hook
      (with-helm-buffer
        (helm-goto-source source)
        (helm-next-line))))
  (helm :buffer "*Helm Clojure Symbols*"
        :candidate-number-limit 9999
        :keymap (helm-cider--apropos-map)
        :preselect (helm-cider--regexp-symbol (cider-symbol-at-point t))
        :sources (helm-cider--apropos-sources nil doc)))

;;;###autoload
(defun helm-cider-apropos-symbol-doc (&optional source)
  "Choose Clojure symbols, with docs, across namespaces.

If SOURCE is provided, puts the selection line on the first
candidate of SOURCE.

Equivalent to `(helm-cider-apropos-symbol SOURCE t)'."
  (interactive)
  (helm-cider-apropos-symbol source t))

;;;###autoload
(defun helm-cider-apropos-ns (&optional ns-or-qualified-name)
  "Choose Clojure namespace to call Helm CIDER apropos on.

NS-OR-QUALIFIED-NAME is a Clojure
namespace (e.g. \"clojure.core\") or a qualified symbol
name (e.g. \"clojure.core/reduce\").  If provided, it is used as
the default selection."
  (interactive)
  (cider-ensure-connected)
  (helm :buffer "*Helm Clojure Namespaces*"
        :keymap (helm-cider--apropos-ns-map)
        :preselect (helm-cider--regexp-symbol (helm-cider--symbol-ns (or ns-or-qualified-name "")))
        :sources (helm-cider--apropos-ns-source)))

;;;###autoload
(defun helm-cider-apropos (&optional arg)
  "Helm interface to CIDER apropos.

If ARG is raw prefix argument \\[universal-argument], include
symbol documentation.

If ARG is raw prefix argument \\[universal-argument]
\\[universal-argument], choose namespace before symbol."
  (interactive "P")
  (cond ((equal arg '(16)) (helm-cider-apropos-ns))
        ((equal arg '(4)) (helm-cider-apropos-symbol-doc))
        (t (helm-cider-apropos-symbol))))


;;;; Key bindings

(define-key cider-mode-map [remap cider-apropos] #'helm-cider-apropos)
(define-key cider-mode-map [remap cider-apropos-select] #'helm-cider-apropos)
(define-key cider-mode-map [remap cider-apropos-documentation] #'helm-cider-apropos-symbol-doc)
(define-key cider-mode-map [remap cider-apropos-documentation-select] #'helm-cider-apropos-symbol-doc)
(define-key cider-mode-map [remap cider-browse-ns] #'helm-cider-apropos-ns)
(define-key cider-mode-map [remap cider-browse-ns-all] #'helm-cider-apropos-ns)


(provide 'helm-cider)
;;; helm-cider.el ends here