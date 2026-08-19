# Contributing / Branch Policy

**Note:** GitHub branch protection rules require GitHub Pro/Team on private repos (this repo is
private). Until that's upgraded, the rules below are convention, not enforced by GitHub — please
follow them anyway:

- `main` = production. Don't push directly; open a PR from `dev` (or a feature branch) into
  `main` and let CI go green first.
- `dev` = default branch, integration target for day-to-day work and feature branches.
- Feature branches: branch off `dev`, PR back into `dev`.
- Repo admins (`OpenSRO`, `opensro`) can push/force-push directly if genuinely needed
  (hotfix, fixing a bad merge) — everyone else goes through a PR.

Revisit real enforced branch protection (or rulesets) once the repo goes public or moves to a
paid plan.
