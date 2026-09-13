# Unapplied kDrive comment setting

Observed 2026-09-12 on the operator-authorized Stability Lab. This is an open
integration failure, not a confirmed account limitation or a proven vendor defect.
No credential, account/file identifier, private URL, or live body is needed here.

On 2026-09-13, the operator accepted this as a non-blocking limitation for the
stability PR because file comments are outside the critical path. Investigation
remains a follow-up under CR-027; the warning and failing scenario are preserved.

## Reproduction

1. Use a generated, disposable plain-text file inside the verified lab subtree.
2. Open Finder → Share kDrive Link, select Inherit Access, and create the link.
3. Enable Allow comments and verify that the checkbox is checked before Save.
4. Save. The update is acknowledged, but the subsequent GET reports comments
   disabled. A comments-only update also reproduced this behavior.
5. The corrected app displays the returned settings and an explicit warning that
   not all settings were applied. It does not claim success or widen access.

A separate temporary public link to the same synthetic-only fixture also returned
comments disabled after an explicitly checked Save. That link was disabled and
a fresh panel reload confirmed no link remained. Inherited access alone therefore
does not explain this probe. The automated scenario continues to use inherited access.

Disabling the generated link works. Independently restricting downloads also
persisted in a manual check. These observations do not establish why comments
were declined or prove that every plan/access/file-type combination behaves alike.

## Public contract and expected behavior

The [official update contract](https://developer.infomaniak.com/docs/api/put/2/drive/%7Bdrive_id%7D/files/%7Bfile_id%7D/link)
documents `can_comment` independently; omission/null inherits `can_edit`.
The app therefore sends explicit comment intent on every actual update and omits
unchanged access settings. It omits an already-absent expiration; JSON null is
reserved for clearing an existing expiration. The typed route, JSON boolean key,
and returned capability mapping have synthetic request/response regression coverage.

The expected result of explicit `can_comment: true` is a subsequent reported
comment capability of true, or an explicit rejection. A successful acknowledgement
with false remaining in the returned capabilities is treated as an unapplied write.

## Remaining evidence needed

A vendor explanation or a comparison through the official kDrive sharing UI on
the same generated file would establish whether this is a service constraint,
a file/access-mode rule, or another integration detail. No message has been sent
to Infomaniak. The strict comments assertion remains in scenario 16; subsequent
link-disable and version-copy checks cannot convert that failure into a pass.
