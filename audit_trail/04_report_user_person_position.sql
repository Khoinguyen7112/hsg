WITH
emp_idx AS (
  SELECT column_id - 8 idx FROM all_tab_columns
  WHERE owner = 'APPLSYS' AND table_name = 'FND_USER_A' AND column_name = 'EMPLOYEE_ID'
),
pos_idx AS (
  SELECT column_id - 8 idx FROM all_tab_columns
  WHERE owner = 'HR' AND table_name = 'PER_ALL_ASSIGNMENTS_F_A' AND column_name = 'POSITION_ID'
),
aud AS (
  SELECT fa.audit_timestamp, fa.audit_sequence_id, fa.audit_transaction_type, fa.audit_user_name,
         fa.assignment_id, fa.effective_start_date, fa.position_id,
         CASE WHEN SUBSTR(fa.audit_true_nulls, (SELECT idx FROM pos_idx), 1) = 'Y'
              THEN 'Y' ELSE 'N' END pos_was_null
  FROM hr.per_all_assignments_f_a fa
),
pos_fix AS (
  SELECT r.assignment_id, r.effective_start_date, r.audit_timestamp, r.audit_sequence_id,
         CASE WHEN r.pos_was_null = 'Y' THEN NULL ELSE r.position_id END old_pos_id
  FROM aud r
  WHERE r.audit_transaction_type = 'U'
    AND (r.position_id IS NOT NULL OR r.pos_was_null = 'Y')
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
ub AS (
  SELECT ua.audit_timestamp, ua.audit_user_name, u.user_name,
         ua.old_person_id, NVL(ua.next_old, u.employee_id) new_person_id
  FROM ua
  JOIN applsys.fnd_user u ON u.user_id = ua.user_id
),
pk AS (
  SELECT audit_timestamp ts, old_person_id person_id FROM ub WHERE old_person_id IS NOT NULL
  UNION
  SELECT audit_timestamp, new_person_id FROM ub WHERE new_person_id IS NOT NULL
),
asg_at AS (
  SELECT pk.ts, pk.person_id,
         CASE
           WHEN (SELECT COUNT(*) FROM aud i
                  WHERE i.audit_transaction_type = 'I'
                    AND i.assignment_id = a.assignment_id
                    AND i.effective_start_date = a.effective_start_date
                    AND i.audit_timestamp > pk.ts) > 0
           THEN (SELECT p.position_id FROM apps.per_all_assignments_f p
                  WHERE p.assignment_id = a.assignment_id
                    AND p.effective_end_date = a.effective_start_date - 1)
           WHEN (SELECT COUNT(*) FROM pos_fix f
                  WHERE f.assignment_id = a.assignment_id
                    AND f.effective_start_date = a.effective_start_date
                    AND f.audit_timestamp > pk.ts) > 0
           THEN (SELECT MAX(f.old_pos_id) KEEP (DENSE_RANK FIRST ORDER BY f.audit_timestamp, f.audit_sequence_id)
                   FROM pos_fix f
                  WHERE f.assignment_id = a.assignment_id
                    AND f.effective_start_date = a.effective_start_date
                    AND f.audit_timestamp > pk.ts)
           ELSE a.position_id
         END position_id
  FROM pk
  JOIN apps.per_all_assignments_f a
    ON a.person_id = pk.person_id
   AND a.primary_flag = 'Y'
   AND a.assignment_type IN ('E','C')
   AND TRUNC(pk.ts) BETWEEN a.effective_start_date AND a.effective_end_date
),
person_chg AS (
  SELECT ub.audit_timestamp, ub.audit_user_name, 'DOI_PERSON' loai, CAST(NULL AS VARCHAR2(10)) kieu,
         TRUNC(ub.audit_timestamp) hieu_luc_tu,
         ub.user_name ebs_user,
         ub.old_person_id, ub.new_person_id,
         o.position_id old_pos_id, n.position_id new_pos_id
  FROM ub
  LEFT JOIN asg_at o ON o.ts = ub.audit_timestamp AND o.person_id = ub.old_person_id
  LEFT JOIN asg_at n ON n.ts = ub.audit_timestamp AND n.person_id = ub.new_person_id
),
corr AS (
  SELECT f.audit_timestamp, f.assignment_id, f.effective_start_date, f.old_pos_id,
         LEAD(f.old_pos_id) OVER (PARTITION BY f.assignment_id, f.effective_start_date
                                  ORDER BY f.audit_timestamp, f.audit_sequence_id) next_old,
         r.audit_user_name
  FROM pos_fix f
  JOIN aud r
    ON r.assignment_id = f.assignment_id AND r.effective_start_date = f.effective_start_date
   AND r.audit_timestamp = f.audit_timestamp AND r.audit_sequence_id = f.audit_sequence_id
),
pos_raw AS (
  SELECT c.audit_timestamp, c.audit_user_name, 'CORRECTION' kieu, c.effective_start_date,
         a.person_id, c.old_pos_id, NVL(c.next_old, a.position_id) new_pos_id
  FROM corr c
  JOIN apps.per_all_assignments_f a
    ON a.assignment_id = c.assignment_id AND a.effective_start_date = c.effective_start_date
  UNION ALL
  SELECT r.audit_timestamp, r.audit_user_name, 'UPDATE', r.effective_start_date,
         cur.person_id, prev.position_id, cur.position_id
  FROM aud r
  JOIN apps.per_all_assignments_f cur
    ON cur.assignment_id = r.assignment_id AND cur.effective_start_date = r.effective_start_date
  LEFT JOIN apps.per_all_assignments_f prev
    ON prev.assignment_id = r.assignment_id AND prev.effective_end_date = r.effective_start_date - 1
  WHERE r.audit_transaction_type = 'I'
    AND DECODE(prev.position_id, cur.position_id, 0, 1) = 1
),
position_chg AS (
  SELECT p.audit_timestamp, p.audit_user_name, 'DOI_POSITION' loai, CAST(p.kieu AS VARCHAR2(10)) kieu,
         p.effective_start_date hieu_luc_tu,
         (SELECT MIN(u.user_name)
                 || CASE WHEN COUNT(*) > 1 THEN ' (+' || (COUNT(*) - 1) || ' user)' END
            FROM applsys.fnd_user u WHERE u.employee_id = p.person_id) ebs_user,
         p.person_id old_person_id, p.person_id new_person_id,
         p.old_pos_id, p.new_pos_id
  FROM pos_raw p
),
seg_vs AS (
  SELECT s.application_column_name col, s.flex_value_set_id vs_id
  FROM apps.fnd_id_flex_segments_vl s
  JOIN apps.fnd_id_flex_structures_vl st
    ON st.application_id = s.application_id AND st.id_flex_code = s.id_flex_code
   AND st.id_flex_num = s.id_flex_num
  WHERE s.application_id = 800 AND s.id_flex_code = 'POS'
    AND st.id_flex_structure_code = 'POSITION_FLEXFIELD'
    AND s.application_column_name IN ('SEGMENT1','SEGMENT2','SEGMENT3')
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
       (SELECT MAX(fv.description) FROM apps.fnd_flex_values_vl fv
         WHERE fv.flex_value_set_id = (SELECT vs_id FROM seg_vs WHERE col = 'SEGMENT1')
           AND fv.flex_value = ddo.segment1) pos_cu_don_vi,
       (SELECT MAX(fv.description) FROM apps.fnd_flex_values_vl fv
         WHERE fv.flex_value_set_id = (SELECT vs_id FROM seg_vs WHERE col = 'SEGMENT2')
           AND fv.flex_value = ddo.segment2) pos_cu_phong_ban,
       (SELECT MAX(fv.description) FROM apps.fnd_flex_values_vl fv
         WHERE fv.flex_value_set_id = (SELECT vs_id FROM seg_vs WHERE col = 'SEGMENT3')
           AND fv.flex_value = ddo.segment3) pos_cu_chuc_vu,
       hpn.name             position_moi,
       (SELECT MAX(fv.description) FROM apps.fnd_flex_values_vl fv
         WHERE fv.flex_value_set_id = (SELECT vs_id FROM seg_vs WHERE col = 'SEGMENT1')
           AND fv.flex_value = ddn.segment1) pos_moi_don_vi,
       (SELECT MAX(fv.description) FROM apps.fnd_flex_values_vl fv
         WHERE fv.flex_value_set_id = (SELECT vs_id FROM seg_vs WHERE col = 'SEGMENT2')
           AND fv.flex_value = ddn.segment2) pos_moi_phong_ban,
       (SELECT MAX(fv.description) FROM apps.fnd_flex_values_vl fv
         WHERE fv.flex_value_set_id = (SELECT vs_id FROM seg_vs WHERE col = 'SEGMENT3')
           AND fv.flex_value = ddn.segment3) pos_moi_chuc_vu
FROM ev
LEFT JOIN apps.per_all_people_f po
       ON po.person_id = ev.old_person_id
      AND TRUNC(ev.audit_timestamp) BETWEEN po.effective_start_date AND po.effective_end_date
LEFT JOIN apps.per_all_people_f pn
       ON pn.person_id = ev.new_person_id
      AND TRUNC(ev.audit_timestamp) BETWEEN pn.effective_start_date AND pn.effective_end_date
LEFT JOIN apps.hr_all_positions_f hpo
       ON hpo.position_id = ev.old_pos_id
      AND ev.hieu_luc_tu BETWEEN hpo.effective_start_date AND hpo.effective_end_date
LEFT JOIN apps.per_position_definitions ddo
       ON ddo.position_definition_id = hpo.position_definition_id
LEFT JOIN apps.hr_all_positions_f hpn
       ON hpn.position_id = ev.new_pos_id
      AND ev.hieu_luc_tu BETWEEN hpn.effective_start_date AND hpn.effective_end_date
LEFT JOIN apps.per_position_definitions ddn
       ON ddn.position_definition_id = hpn.position_definition_id
ORDER BY ev.audit_timestamp DESC;
