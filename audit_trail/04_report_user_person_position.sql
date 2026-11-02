-- =============================================================================
-- Bao cao tong hop: doi Person cua user (FND_USER_A) + doi Position cua Person (PER_ALL_ASSIGNMENTS_F_A)
-- Moi dong la 1 su kien, sap theo thoi gian.
--   DOI_PERSON   : user EBS duoc gan sang Person khac. Kem Position cua Person cu/moi tai thoi diem doi.
--   DOI_POSITION : Person doi Position (UPDATE = date-track Update, CORRECTION = sua de).
-- Ghi chu:
--   - FND_USER_A luu gia tri CU; gia tri moi = gia tri cu cua lan doi ke tiep, hoac gia tri hien tai.
--   - Bang log HR gia dinh nam o schema HR.
--   - Vi tri cot trong AUDIT_TRUE_NULLS tinh tu dba_tab_columns (sau 8 cot AUDIT_*/ROW_KEY).
-- =============================================================================
WITH
-- ---------- FND_USER: doi Person ----------
emp_idx AS (
  SELECT column_id - 8 idx FROM dba_tab_columns
  WHERE owner = 'APPLSYS' AND table_name = 'FND_USER_A' AND column_name = 'EMPLOYEE_ID'
),
ua AS (
  SELECT fa.audit_timestamp, fa.audit_user_name, fa.user_id,
         CASE WHEN SUBSTR(fa.audit_true_nulls, (SELECT idx FROM emp_idx), 1) = 'Y'
              THEN NULL ELSE fa.employee_id END old_person_id,
         LEAD(CASE WHEN SUBSTR(fa.audit_true_nulls, (SELECT idx FROM emp_idx), 1) = 'Y'
                   THEN NULL ELSE fa.employee_id END)
           OVER (PARTITION BY fa.user_id ORDER BY fa.audit_timestamp, fa.audit_sequence_id) next_old
  FROM applsys.fnd_user_a fa
  WHERE fa.audit_transaction_type = 'U'
    AND (fa.employee_id IS NOT NULL
         OR SUBSTR(fa.audit_true_nulls, (SELECT idx FROM emp_idx), 1) = 'Y')
),
person_chg AS (
  SELECT ua.audit_timestamp, ua.audit_user_name, 'DOI_PERSON' loai, CAST(NULL AS VARCHAR2(10)) kieu,
         TRUNC(ua.audit_timestamp) hieu_luc_tu,
         u.user_name ebs_user,
         ua.old_person_id, NVL(ua.next_old, u.employee_id) new_person_id,
         -- Position cua tung Person tai thoi diem doi
         (SELECT a.position_id FROM per_all_assignments_f a
           WHERE a.person_id = ua.old_person_id AND a.primary_flag = 'Y'
             AND a.assignment_type IN ('E','C')
             AND TRUNC(ua.audit_timestamp) BETWEEN a.effective_start_date AND a.effective_end_date
             AND ROWNUM = 1) old_pos_id,
         (SELECT a.position_id FROM per_all_assignments_f a
           WHERE a.person_id = NVL(ua.next_old, u.employee_id) AND a.primary_flag = 'Y'
             AND a.assignment_type IN ('E','C')
             AND TRUNC(ua.audit_timestamp) BETWEEN a.effective_start_date AND a.effective_end_date
             AND ROWNUM = 1) new_pos_id
  FROM ua
  JOIN applsys.fnd_user u ON u.user_id = ua.user_id
),
-- ---------- HR: doi Position ----------
pos_idx AS (
  SELECT column_id - 8 idx FROM dba_tab_columns
  WHERE owner = 'HR' AND table_name = 'PER_ALL_ASSIGNMENTS_F_A' AND column_name = 'POSITION_ID'
),
aud AS (
  SELECT fa.audit_timestamp, fa.audit_sequence_id, fa.audit_transaction_type, fa.audit_user_name,
         fa.assignment_id, fa.effective_start_date, fa.position_id,
         CASE WHEN SUBSTR(fa.audit_true_nulls, (SELECT idx FROM pos_idx), 1) = 'Y'
              THEN 'Y' ELSE 'N' END pos_was_null
  FROM hr.per_all_assignments_f_a fa
),
corr AS (
  SELECT r.audit_timestamp, r.audit_user_name, r.assignment_id, r.effective_start_date,
         CASE WHEN r.pos_was_null = 'Y' THEN NULL ELSE r.position_id END old_pos_id,
         LEAD(CASE WHEN r.pos_was_null = 'Y' THEN NULL ELSE r.position_id END)
           OVER (PARTITION BY r.assignment_id, r.effective_start_date
                 ORDER BY r.audit_timestamp, r.audit_sequence_id) next_old
  FROM aud r
  WHERE r.audit_transaction_type = 'U'
    AND (r.position_id IS NOT NULL OR r.pos_was_null = 'Y')
),
pos_raw AS (
  SELECT c.audit_timestamp, c.audit_user_name, 'CORRECTION' kieu, c.effective_start_date,
         a.person_id, c.old_pos_id, NVL(c.next_old, a.position_id) new_pos_id
  FROM corr c
  JOIN per_all_assignments_f a
    ON a.assignment_id = c.assignment_id AND a.effective_start_date = c.effective_start_date
  UNION ALL
  SELECT r.audit_timestamp, r.audit_user_name, 'UPDATE', r.effective_start_date,
         cur.person_id, prev.position_id, cur.position_id
  FROM aud r
  JOIN per_all_assignments_f cur
    ON cur.assignment_id = r.assignment_id AND cur.effective_start_date = r.effective_start_date
  LEFT JOIN per_all_assignments_f prev
    ON prev.assignment_id = r.assignment_id AND prev.effective_end_date = r.effective_start_date - 1
  WHERE r.audit_transaction_type = 'I'
    AND DECODE(prev.position_id, cur.position_id, 0, 1) = 1
),
position_chg AS (
  SELECT p.audit_timestamp, p.audit_user_name, 'DOI_POSITION' loai, CAST(p.kieu AS VARCHAR2(10)) kieu,
         p.effective_start_date hieu_luc_tu,
         (SELECT LISTAGG(u.user_name, ', ') WITHIN GROUP (ORDER BY u.user_name)
            FROM applsys.fnd_user u WHERE u.employee_id = p.person_id) ebs_user,
         p.person_id old_person_id, p.person_id new_person_id,
         p.old_pos_id, p.new_pos_id
  FROM pos_raw p
),
ev AS (
  SELECT * FROM person_chg
  UNION ALL
  SELECT * FROM position_chg
)
SELECT ev.audit_timestamp   thoi_diem_doi,
       ev.audit_user_name   nguoi_doi,
       ev.loai,
       ev.kieu              kieu_doi,
       ev.hieu_luc_tu,
       ev.ebs_user,
       po.full_name         person_cu,
       pn.full_name         person_moi,
       hpo.name             position_cu,
       hpn.name             position_moi
FROM ev
LEFT JOIN per_all_people_f po
       ON po.person_id = ev.old_person_id
      AND TRUNC(ev.audit_timestamp) BETWEEN po.effective_start_date AND po.effective_end_date
LEFT JOIN per_all_people_f pn
       ON pn.person_id = ev.new_person_id
      AND TRUNC(ev.audit_timestamp) BETWEEN pn.effective_start_date AND pn.effective_end_date
LEFT JOIN hr_all_positions_f hpo
       ON hpo.position_id = ev.old_pos_id
      AND ev.hieu_luc_tu BETWEEN hpo.effective_start_date AND hpo.effective_end_date
LEFT JOIN hr_all_positions_f hpn
       ON hpn.position_id = ev.new_pos_id
      AND ev.hieu_luc_tu BETWEEN hpn.effective_start_date AND hpn.effective_end_date
ORDER BY ev.audit_timestamp DESC;
