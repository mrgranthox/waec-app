//! WAEC portal HTML parsers — plan §2.4.
//!
//! Decoupled DOM schema validation: each portal has an explicit schema
//! (required selectors). On ANY mismatch: clean abort — no partial
//! parse, no partial results — and a DomDrift alert fires upstream.
//! Hard rule 7: never parse "best effort".

use scraper::{Html, Selector};
use waec_common::errors::{DomainError, ErrorCode};
use waec_common::pb::waec::common::v1::SubjectGrade;

/// Parsed candidate result. Contains grades — never persisted, never logged.
#[derive(Debug, Clone, PartialEq)]
pub struct ParsedResult {
    pub candidate_name: String,
    pub index_number: String,
    pub exam_year: String,
    pub grades: Vec<SubjectGrade>,
    pub aggregate: String,
}

/// The DOM schema one portal must satisfy.
#[derive(Debug, Clone)]
pub struct PortalSchema {
    pub portal_host: &'static str,
    /// CSS selector for the candidate name cell.
    pub name_selector: &'static str,
    /// CSS selector for the index number cell.
    pub index_selector: &'static str,
    /// CSS selector for the exam year cell.
    pub year_selector: &'static str,
    /// CSS selector producing the grades table rows.
    pub grade_rows_selector: &'static str,
    /// CSS selector for subject cell within a row.
    pub subject_cell_selector: &'static str,
    /// CSS selector for grade cell within a row.
    pub grade_cell_selector: &'static str,
    /// CSS selector for aggregate summary.
    pub aggregate_selector: &'static str,
}

/// eresults.waecgh.org schema (BECE / WASSCE School).
pub const ERESULTS_SCHEMA: PortalSchema = PortalSchema {
    portal_host: "eresults.waecgh.org",
    name_selector: "div.candidate-name",
    index_selector: "div.candidate-index",
    year_selector: "div.exam-year",
    grade_rows_selector: "table.grades tbody tr",
    subject_cell_selector: "td.subject",
    grade_cell_selector: "td.grade",
    aggregate_selector: "div.aggregate",
};

/// ghana.waecdirect.org schema (WASSCE Private / Nov-Dec).
pub const WAECDIRECT_SCHEMA: PortalSchema = PortalSchema {
    portal_host: "ghana.waecdirect.org",
    name_selector: "span#candidateName",
    index_selector: "span#candidateIndex",
    year_selector: "span#examYear",
    grade_rows_selector: "table#gradesTable tbody tr",
    subject_cell_selector: "td.subject",
    grade_cell_selector: "td.grade",
    aggregate_selector: "span#aggregate",
};

/// A DOM-drift event payload (Admin alert routing; no candidate data).
#[derive(Debug, Clone, PartialEq)]
pub struct DomDriftAlert {
    pub portal_host: &'static str,
    pub missing_selector: String,
}

/// Parse raw HTML against a strict schema. Any missing anchor aborts
/// with `WaecDomSchemaDrift` — the caller alerts + schedules retry.
pub fn parse_result(
    schema: &PortalSchema,
    html: &str,
) -> Result<ParsedResult, (DomainError, Option<DomDriftAlert>)> {
    let drift = |sel: &str| {
        (
            DomainError::new(
                ErrorCode::WaecDomSchemaDrift,
                format!("DOM drift on {}: missing {}", schema.portal_host, sel),
            ),
            Some(DomDriftAlert {
                portal_host: schema.portal_host,
                missing_selector: sel.to_string(),
            }),
        )
    };

    let doc = Html::parse_document(html);

    let text_of = |sel: &str| -> Result<String, (DomainError, Option<DomDriftAlert>)> {
        let selector = Selector::parse(sel).map_err(|_| drift(sel))?;
        doc.select(&selector)
            .next()
            .map(|el| el.text().collect::<String>().trim().to_string())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| drift(sel))
    };

    let candidate_name = text_of(schema.name_selector)?;
    let index_number = text_of(schema.index_selector)?;
    let exam_year = text_of(schema.year_selector)?;
    let aggregate = text_of(schema.aggregate_selector).unwrap_or_default();

    // Grades table: every row must carry both cells; a broken row is drift.
    let rows_sel = Selector::parse(schema.grade_rows_selector)
        .map_err(|_| drift(schema.grade_rows_selector))?;
    let subj_sel = Selector::parse(schema.subject_cell_selector)
        .map_err(|_| drift(schema.subject_cell_selector))?;
    let grade_sel = Selector::parse(schema.grade_cell_selector)
        .map_err(|_| drift(schema.grade_cell_selector))?;

    let mut grades = Vec::new();
    for row in doc.select(&rows_sel) {
        let subject = row
            .select(&subj_sel)
            .next()
            .map(|el| el.text().collect::<String>().trim().to_string());
        let grade = row
            .select(&grade_sel)
            .next()
            .map(|el| el.text().collect::<String>().trim().to_string());
        match (subject, grade) {
            (Some(s), Some(g)) if !s.is_empty() && !g.is_empty() => {
                grades.push(SubjectGrade {
                    subject: s,
                    grade: g,
                });
            }
            _ => return Err(drift(schema.grade_rows_selector)),
        }
    }
    if grades.is_empty() {
        return Err(drift(schema.grade_rows_selector));
    }

    Ok(ParsedResult {
        candidate_name,
        index_number,
        exam_year,
        grades,
        aggregate,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_eresults() -> String {
        r#"<html><body>
            <div class="candidate-name">ADJEI KWAME</div>
            <div class="candidate-index">1002330440</div>
            <div class="exam-year">2025</div>
            <table class="grades"><tbody>
            <tr><td class="subject">MATHEMATICS</td><td class="grade">A1</td></tr>
            <tr><td class="subject">ENGLISH</td><td class="grade">B2</td></tr>
            </tbody></table>
            <div class="aggregate">6</div>
            </body></html>"#
            .into()
    }

    #[test]
    fn parses_eresults_schema() {
        let r = parse_result(&ERESULTS_SCHEMA, &fixture_eresults()).unwrap();
        assert_eq!(r.candidate_name, "ADJEI KWAME");
        assert_eq!(r.index_number, "1002330440");
        assert_eq!(r.grades.len(), 2);
        assert_eq!(r.grades[0].subject, "MATHEMATICS");
        assert_eq!(r.aggregate, "6");
    }

    #[test]
    fn parses_waecdirect_schema() {
        let html = r#"<html><body>
            <span id="candidateName">MANU JOHN</span>
            <span id="candidateIndex">2001223440</span>
            <span id="examYear">2024</span>
            <table id="gradesTable"><tbody>
            <tr><td class="subject">PHYSICS</td><td class="grade">B3</td></tr>
            </tbody></table>
            <span id="aggregate">12</span>
            </body></html>"#;
        let r = parse_result(&WAECDIRECT_SCHEMA, html).unwrap();
        assert_eq!(r.candidate_name, "MANU JOHN");
        assert_eq!(r.grades[0].grade, "B3");
    }

    #[test]
    fn dom_drift_aborts_cleanly_with_alert() {
        // WAEC "redesigned": name moved into a <p>, table class renamed.
        let drifted = r#"<html><body>
            <p class="studentFullName">ADJEI KWAME</p>
            <div class="candidate-index">1002330440</div>
            <div class="exam-year">2025</div>
            <table class="results-grid"><tbody>
            <tr><td>MATHEMATICS</td><td>A1</td></tr>
            </tbody></table>
            </body></html>"#;
        let (err, alert) = parse_result(&ERESULTS_SCHEMA, drifted).unwrap_err();
        assert_eq!(err.code, ErrorCode::WaecDomSchemaDrift);
        let alert = alert.expect("drift alert must fire");
        assert_eq!(alert.portal_host, "eresults.waecgh.org");
        assert!(!alert.missing_selector.is_empty());
    }

    #[test]
    fn empty_html_is_drift_not_partial() {
        let (_, alert) = parse_result(&ERESULTS_SCHEMA, "<html></html>").unwrap_err();
        assert!(alert.is_some());
    }

    #[test]
    fn broken_grade_row_aborts_no_partial_results() {
        let html = r#"<html><body>
            <div class="candidate-name">X Y</div>
            <div class="candidate-index">1002330440</div>
            <div class="exam-year">2025</div>
            <table class="grades"><tbody>
            <tr><td class="subject">MATH</td><td class="grade">A1</td></tr>
            <tr><td class="subject">ENGLISH</td></tr>
            </tbody></table>
            <div class="aggregate">6</div>
            </body></html>"#;
        let (err, _) = parse_result(&ERESULTS_SCHEMA, html).unwrap_err();
        assert_eq!(err.code, ErrorCode::WaecDomSchemaDrift);
    }

    #[test]
    fn empty_grades_table_is_drift() {
        let html = r#"<html><body>
            <div class="candidate-name">X Y</div>
            <div class="candidate-index">1002330440</div>
            <div class="exam-year">2025</div>
            <table class="grades"><tbody></tbody></table>
            <div class="aggregate"></div>
            </body></html>"#;
        assert!(parse_result(&ERESULTS_SCHEMA, html).is_err());
    }
}
