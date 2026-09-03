use regex::Regex;

#[derive(Clone, Debug)]
pub enum SizeOp {
    Gt(u64),
    Lt(u64),
    Eq(u64),
}

#[derive(Clone, Debug)]
pub enum DateOp {
    Today,
    Yesterday,
    ThisWeek,
    ThisMonth,
    Gt(u64),
    Lt(u64),
}

#[derive(Clone, Debug)]
pub enum QueryNode {
    Contains(String),
    Extension(String),
    PathContains(String),
    RegexMatch(Regex),
    Size(SizeOp),
    Date(DateOp),
    Kind(String),
    And(Vec<QueryNode>),
    Or(Vec<QueryNode>),
    Not(Box<QueryNode>),
    /// Matches nothing (e.g. an invalid regex). Prevents misleading full matches.
    NoMatch,
}

pub struct QueryParser;

impl QueryParser {
    pub fn parse(query: &str) -> QueryNode {
        let mut and_nodes = Vec::new();

        let query_trim = query.trim();

        // Match regex shorthand like /^IMG_\d{4}\.jpg$/
        if query_trim.starts_with('/') && query_trim.ends_with('/') && query_trim.len() > 2 {
            let term = &query_trim[1..query_trim.len() - 1];
            if let Ok(re) = Regex::new(&format!("(?i){}", term)) {
                return QueryNode::RegexMatch(re);
            }
            return QueryNode::NoMatch;
        }

        if query_trim.starts_with("regex:") {
            let term = query_trim.strip_prefix("regex:").unwrap();
            if let Ok(re) = Regex::new(&format!("(?i){}", term)) {
                return QueryNode::RegexMatch(re);
            }
            return QueryNode::NoMatch;
        }

        let query_normalized = query_trim
            .replace("ext: ", "ext:")
            .replace("size: ", "size:")
            .replace("date: ", "date:")
            .replace("kind: ", "kind:")
            .replace("in: ", "in:")
            .replace("path: ", "path:");

        let parts: Vec<&str> = query_normalized.split_whitespace().collect();

        for part in parts {
            if part.starts_with("!") {
                let term = part.strip_prefix("!").unwrap();
                if !term.is_empty() {
                    and_nodes.push(QueryNode::Not(Box::new(QueryNode::Contains(term.to_lowercase()))));
                }
            } else if part.starts_with("ext:") {
                let term = part.strip_prefix("ext:").unwrap();
                if term.contains('|') {
                    let or_parts: Vec<&str> = term.split('|').collect();
                    let mut or_nodes = Vec::new();
                    for op in or_parts {
                        if !op.is_empty() {
                            or_nodes.push(QueryNode::Extension(op.to_lowercase()));
                        }
                    }
                    if !or_nodes.is_empty() {
                        and_nodes.push(QueryNode::Or(or_nodes));
                    }
                } else {
                    and_nodes.push(QueryNode::Extension(term.to_lowercase()));
                }
            } else if part.starts_with("path:") || part.starts_with("in:") {
                let term = if part.starts_with("path:") {
                    part.strip_prefix("path:").unwrap()
                } else {
                    part.strip_prefix("in:").unwrap()
                };
                and_nodes.push(QueryNode::PathContains(term.to_lowercase()));
            } else if part.starts_with("kind:") {
                let term = part.strip_prefix("kind:").unwrap();
                if term.contains('|') {
                    let or_parts: Vec<&str> = term.split('|').collect();
                    let mut or_nodes = Vec::new();
                    for op in or_parts {
                        if !op.is_empty() {
                            or_nodes.push(QueryNode::Kind(op.to_lowercase()));
                        }
                    }
                    if !or_nodes.is_empty() {
                        and_nodes.push(QueryNode::Or(or_nodes));
                    }
                } else {
                    and_nodes.push(QueryNode::Kind(term.to_lowercase()));
                }
            } else if part.starts_with("size:") {
                let term = part.strip_prefix("size:").unwrap().to_lowercase();
                if let Some(node) = Self::parse_size_op(&term) {
                    and_nodes.push(node);
                }
            } else if part.starts_with("date:") {
                let term = part.strip_prefix("date:").unwrap().to_lowercase();
                if let Some(node) = Self::parse_date_op(&term) {
                    and_nodes.push(node);
                }
            } else if part.starts_with("regex:") {
                let term = part.strip_prefix("regex:").unwrap();
                if let Ok(re) = Regex::new(&format!("(?i){}", term)) {
                    and_nodes.push(QueryNode::RegexMatch(re));
                } else {
                    and_nodes.push(QueryNode::NoMatch);
                }
            } else if part.contains('|') {
                let or_parts: Vec<&str> = part.split('|').collect();
                let mut or_nodes = Vec::new();
                for op in or_parts {
                    if !op.is_empty() {
                        or_nodes.push(QueryNode::Contains(op.to_lowercase()));
                    }
                }
                if !or_nodes.is_empty() {
                    and_nodes.push(QueryNode::Or(or_nodes));
                }
            } else {
                and_nodes.push(QueryNode::Contains(part.to_lowercase()));
            }
        }

        if and_nodes.is_empty() {
            QueryNode::Contains("".to_string())
        } else if and_nodes.len() == 1 {
            and_nodes.pop().unwrap()
        } else {
            QueryNode::And(and_nodes)
        }
    }

    fn parse_size_op(term: &str) -> Option<QueryNode> {
        let (op_char, num_part) = if let Some(rest) = term.strip_prefix('>') {
            (1u8, rest)
        } else if let Some(rest) = term.strip_prefix('<') {
            (2u8, rest)
        } else {
            (0u8, term) // exact match (no operator)
        };

        let mut multiplier = 1u64;
        let mut num_str = num_part;
        if num_part.ends_with("kb") {
            multiplier = 1024;
            num_str = &num_part[..num_part.len() - 2];
        } else if num_part.ends_with("mb") {
            multiplier = 1024 * 1024;
            num_str = &num_part[..num_part.len() - 2];
        } else if num_part.ends_with("gb") {
            multiplier = 1024 * 1024 * 1024;
            num_str = &num_part[..num_part.len() - 2];
        }

        if let Ok(val) = num_str.parse::<f64>() {
            let bytes = (val * multiplier as f64) as u64;
            return match op_char {
                1 => Some(QueryNode::Size(SizeOp::Gt(bytes))),
                2 => Some(QueryNode::Size(SizeOp::Lt(bytes))),
                _ => Some(QueryNode::Size(SizeOp::Eq(bytes))),
            };
        }
        None
    }

    fn parse_date_op(term: &str) -> Option<QueryNode> {
        if term == "today" {
            return Some(QueryNode::Date(DateOp::Today));
        }
        if term == "yesterday" {
            return Some(QueryNode::Date(DateOp::Yesterday));
        }
        if term == "thisweek" {
            return Some(QueryNode::Date(DateOp::ThisWeek));
        }
        if term == "thismonth" {
            return Some(QueryNode::Date(DateOp::ThisMonth));
        }
        None
    }
}
