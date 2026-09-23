// Builds the Flux diff PR comment and job summary from flux_diff.sh's output
// and keeps one sticky comment per pull request, updated in place. Loaded by
// actions/github-script in .github/workflows/flux-diff.yaml.
//
// Inputs arrive through the environment, never by interpolating `${{ }}` into
// script source: the diff is untrusted text from the PR, and an expression
// expanded into source could break out of a string and run as code.
//   DIFF_FILE  the rendered diff, in flate's `github` output style
//   LOG_FILE   flux_diff.sh's stderr (flate's log)
//   EXIT       flux_diff.sh's exit code: 0 rendered, 1 the PR's side fails to
//              render, 2 only the merge-base fails to render
//   BASE_SHA, HEAD_SHA

const fs = require('fs');

const MARKER = '<!-- flux-diff -->';
const COMMENT_LIMIT = 65000; // GitHub caps a comment at 65536 characters; the rest is headroom
const SUMMARY_LIMIT = 1000000; // and a job summary at 1 MiB

const fence = (lang, text) => '````' + lang + '\n' + text + '\n````';

module.exports = async ({ github, context, core }) => {
  const diff = fs.readFileSync(process.env.DIFF_FILE, 'utf8');
  const log = fs.readFileSync(process.env.LOG_FILE, 'utf8');
  const exit = process.env.EXIT;
  const base = process.env.BASE_SHA.slice(0, 7);
  const head = process.env.HEAD_SHA.slice(0, 7);
  const runUrl = `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;
  const empty = diff.trim() === '';

  const parts = [
    MARKER,
    '## Flux diff',
    `What Flux would apply differently at \`${head}\` than at the merge-base \`${base}\`, ` +
      'rendered offline by [flate](https://github.com/home-operations/flate) ' +
      `([workflow run](${runUrl}); README.md → "Continuous integration" explains how to read it).`,
  ];

  if (exit !== '0') {
    if (exit === '2') {
      parts.push(
        '> [!WARNING]\n' +
          "> The merge-base fails to render (log below); this PR's side renders clean, so the job passes. " +
          'Resources that could not be rendered there appear below as `diff suppressed`.',
      );
    } else {
      let note =
        '> [!CAUTION]\n' +
        `> flux_diff.sh exited ${exit}: something on this PR's side failed to render. ` +
        'Flux would fail the same way, so fix it before merging. ' +
        'In the log, "orig snapshot" is the merge-base and "current snapshot" is this PR.';
      if (log.includes('status code 429')) {
        note +=
          '\n>\n> A chart pull hit a registry rate limit (429) even after retries; ' +
          "that is the runner's shared IP, not this PR. Re-run the job.";
      }
      parts.push(note);
    }
    parts.push(fence('text', log.trim().split('\n').slice(-60).join('\n')));
  }

  if (empty) {
    parts.push('No rendered changes.');
  } else {
    // The diff gets whatever the cap leaves after the header, the notes, and
    // the log tail (flate's error lines run long), so budget from the rest
    // rather than from a fixed number.
    const note = `> [!NOTE]\n> Truncated; the full diff is in the [job summary](${runUrl}).`;
    const room = () => COMMENT_LIMIT - [...parts, fence('diff', '')].join('\n\n').length;
    if (diff.length > room()) {
      parts.push(note);
      parts.push(fence('diff', diff.slice(0, Math.max(0, room()))));
    } else {
      parts.push(fence('diff', diff));
    }
  }
  const body = parts.join('\n\n');

  await core.summary
    .addRaw('## Flux diff\n\n' + (empty ? 'No rendered changes.' : fence('diff', diff.slice(0, SUMMARY_LIMIT))) + '\n')
    .write();

  // Sticky: update the comment carrying MARKER if there is one, else create it.
  // Dependabot and fork PRs run with a read-only token; the job summary still
  // has the diff, so warn rather than fail when posting is refused.
  const { owner, repo } = context.repo;
  const issue_number = context.issue.number;
  try {
    const comments = await github.paginate(github.rest.issues.listComments, { owner, repo, issue_number, per_page: 100 });
    const existing = comments.find((c) => c.body && c.body.includes(MARKER));
    if (existing) {
      await github.rest.issues.updateComment({ owner, repo, comment_id: existing.id, body });
    } else {
      await github.rest.issues.createComment({ owner, repo, issue_number, body });
    }
  } catch (err) {
    core.warning(`could not post the PR comment (read-only token?): ${err.message}`);
  }
};
