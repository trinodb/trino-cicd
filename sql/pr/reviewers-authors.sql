-- Reviewer-author engagement
WITH
all_members AS (
    SELECT
        org
      , team_slug
      , login
      -- joined_at is an approximate, recorded when membership was checked; assume membership is as old as possible, so stretch it to the end of the previous row
      , coalesce(lag(removed_at) OVER (PARTITION BY org, login, team_slug ORDER BY joined_at) + interval '1' second, timestamp '0001-01-01') AS joined_at
      , removed_at
    FROM timestamped_members
)
, org_members AS (
    SELECT
        login
      , joined_at
      , removed_at
      , array_agg(org) AS orgs
    FROM all_members
    WHERE team_slug = '' AND org != 'trinodb'
    GROUP BY 1, 2, 3
)
, team_members AS (
    SELECT
        login
      , joined_at
      , removed_at
      , array_agg(team_slug) AS teams
    FROM timestamped_members
    -- TODO how to filter out contributors for maintainers since it's a subset?
    WHERE team_slug NOT IN ('', 'infrastructure') AND org = 'trinodb'
    GROUP BY 1, 2, 3
)
, reviews AS (
    SELECT
        r.submitted_at AS review_time
      , r.pull_number
      , r.state
      , p.user_login AS author
      , r.user_login AS reviewer
      , count(*) AS comments
      , count(*) FILTER (WHERE rc.in_reply_to_id != 0) AS replies
    FROM reviews r
    JOIN unique_pulls p ON (p.owner, p.repo, p.number) = (r.owner, r.repo, r.pull_number)
    LEFT JOIN review_comments rc ON (r.owner, r.repo, r.id) = (rc.owner, rc.repo, rc.pull_request_review_id)
    WHERE r.owner = 'trinodb' AND r.repo = 'trino'
    AND r.user_login != p.user_login AND r.submitted_at > CURRENT_DATE - interval '1' year
    GROUP BY 1, 2, 3, 4, 5
)
, review_counts AS (
    SELECT
        reviewer
      , author
      , sum(comments) AS num_review_comments
      , sum(replies) AS num_comment_replies
      , count(distinct pull_number) AS num_prs
      , count(distinct pull_number)
        / (select cast(count(distinct pull_number) AS double) FROM reviews) AS frac_prs
      , count(*) AS num_reviews
      , count(*) FILTER (WHERE comments = replies) AS num_review_replies
      , count(*) FILTER (WHERE state = 'APPROVED') AS num_approvals
      , count(distinct pull_number) FILTER (WHERE state = 'APPROVED')
        / (select cast(count(distinct pull_number) AS double) FROM reviews WHERE state = 'APPROVED') AS frac_approvals
      , row_number() OVER (PARTITION BY reviewer ORDER BY sum(comments) DESC) AS author_rank
    FROM reviews
    GROUP BY 1, 2
)
, comments AS (
    SELECT
        p.user_login AS author
      , pc.user_login AS reviewer
      , count(*) FILTER (WHERE p.user_login = pc.user_login) AS num_pr_author_comments
      , count(*) FILTER (WHERE p.user_login != pc.user_login) AS num_pr_reviewer_comments
    FROM unique_pulls P
    JOIN unique_issue_comments pc ON pc.issue_url = p.issue_url
    WHERE p.owner = 'trinodb' AND p.repo = 'trino'
    AND pc.created_at > CURRENT_DATE - interval '1' year
    -- exclude reviewers commenting on own PRs, assuming these are mostly responses
    AND p.user_login != pc.user_login
    GROUP BY 1, 2
)
, commits AS (
    SELECT
        c.committer_login AS merger
      , p.user_login AS author
      , count(*) AS num_merged_commits
    FROM unique_pulls p
    JOIN unique_pull_commits c ON (p.owner, p.repo, p.number) = (c.owner, c.repo, c.pull_number)
    WHERE p.owner = 'trinodb' AND p.repo = 'trino'
    AND c.committer_date > CURRENT_DATE - interval '1' year
    -- exclude reviewers merging on own PRs
    AND c.committer_login != p.user_login
    GROUP BY 1, 2
)
SELECT
    ri.name || coalesce(nullif(' (' || array_join(coalesce(omr.orgs, ARRAY[]) || coalesce(tmr.teams, ARRAY[]), ', ') || ')', ' ()'), '') AS "Reviewer name"
  , ai.name || coalesce(nullif(' (' || array_join(coalesce(oma.orgs, ARRAY[]) || coalesce(tma.teams, ARRAY[]), ', ') || ')', ' ()'), '') AS "Author name"
  , author_rank AS "Author rank"
  , bar(num_review_comments / CAST(max(num_review_comments) OVER (PARTITION BY coalesce(rc.reviewer, cnt.reviewer, cit.merger)) AS double), 20, rgb(0, 155, 0), rgb(255, 0, 0)) AS "Comments chart"
  , num_review_comments AS "Review comments"
  , num_comment_replies AS "Comment replies"
  , num_prs AS "Number of PRs"
  , format('%.2f', 100 * frac_prs) AS "Reviewed PRs %"
  , format('%.2f', 100 * frac_approvals) "Approved PRs %"
  , num_reviews "Number of reviews"
  , num_review_replies "Number of replies"
  , num_approvals "Number of approvals"
  , num_pr_author_comments AS "PR author comments"
  , num_pr_reviewer_comments AS "PR reviewer comments"
  , num_merged_commits AS "Merged commits"
FROM review_counts rc
FULL OUTER JOIN comments cnt ON (rc.reviewer, rc.author) = (cnt.reviewer, cnt.author)
FULL OUTER JOIN commits cit ON (rc.reviewer, rc.author) = (cit.merger, cit.author)
JOIN memory.default.gh_idents ri ON CONTAINS(ri.logins, coalesce(rc.reviewer, cnt.reviewer, cit.merger))
JOIN memory.default.gh_idents ai ON CONTAINS(ai.logins, coalesce(rc.author, cnt.author, cit.author))
LEFT JOIN org_members oma ON CONTAINS(ai.logins, oma.login)
LEFT JOIN team_members tma ON CONTAINS(ai.logins, tma.login)
LEFT JOIN org_members omr ON CONTAINS(ri.logins, omr.login)
LEFT JOIN team_members tmr ON CONTAINS(ri.logins, tmr.login)
ORDER BY "Reviewer name", "Review comments" DESC, "Author name"
;
