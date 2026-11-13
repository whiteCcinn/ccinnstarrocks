import Foundation

/// Keyword and function vocabulary for MySQL-compatible StarRocks SQL.
public enum SQLKeywords {
    /// Words highlighted as keywords.
    public static let all: Set<String> = Set("""
    ACTIVE ADD ADMIN AGGREGATE ALL ALTER ANALYZE AND ANTI ARRAY AS ASC ASYNC BACKENDS BACKUP BEGIN BETWEEN BIGINT BINARY \
    BITMAP BOOLEAN BROKER BUCKETS BY CANCEL CASE CAST CATALOG CATALOGS CHAR COLUMN COLUMNS COMMENT COMMIT COMPUTE \
    COSTS CREATE CROSS CURRENT DATA DATABASE DATABASES DATE DATETIME DAY DECIMAL DEFAULT DELETE DESC DESCRIBE \
    DISTINCT DISTRIBUTED DISTRIBUTION DOUBLE DROP DUPLICATE ELSE END ENGINE EVERY EXCEPT EXISTS EXPLAIN EXPORT \
    EXTERNAL FALSE FILES FIRST FLOAT FOLLOWING FOR FORCE FORMAT FROM FRONTENDS FULL FUNCTION FUNCTIONS GLOBAL GRANT \
    GROUP HASH HAVING HLL HOUR IF IGNORE IN INACTIVE INDEX INNER INSERT INT INTERSECT INTERVAL INTO IS JOIN JSON KEY \
    KEYS KILL LABEL LARGEINT LAST LATERAL LEFT LESS LIKE LIMIT LIST LOAD MANUAL MAP MATERIALIZED MAXVALUE MINUS \
    MINUTE MODIFY MONTH NODES NOT NULL NULLS OFFSET ON OR ORDER OUTER OUTFILE OVER OVERWRITE PARTITION PARTITIONS \
    PAUSE PERCENTILE PIPE PRECEDING PRIMARY PRIVILEGES PROC PROCESSLIST PROPERTIES QUARTER QUERY RANDOM RANGE \
    RECURSIVE REFRESH REGEXP RENAME REPLACE REPLICA RESOURCE RESTORE RESUME REVOKE RIGHT RLIKE ROLE ROLLBACK ROLLUP \
    ROUTINE ROW ROWS SCHEMA SECOND SELECT SEMI SESSION SET SHOW SMALLINT SNAPSHOT START STATUS STOP STORAGE STRING \
    STRUCT SUBMIT SWAP SYNC TABLE TABLES TABLET TASK TEMPORARY THAN THEN TIMESTAMP TINYINT TO TRUE TRUNCATE \
    UNBOUNDED UNION UNIQUE UNNEST UPDATE USE USER USING VALUES VARBINARY VARCHAR VARIABLES VERBOSE VIEW WAREHOUSE \
    WEEK WHEN WHERE WINDOW WITH YEAR
    """.split(separator: " ").map(String.init))

    /// Words that must be back-quoted when used as identifiers.
    public static let reserved: Set<String> = Set("""
    ADD ALL ALTER ANALYZE AND ANTI AS ASC BETWEEN BIGINT BINARY BY CASE CAST CHAR COLUMN CREATE CROSS CURRENT \
    DATABASE DATABASES DECIMAL DEFAULT DELETE DESC DESCRIBE DISTINCT DOUBLE DROP ELSE EXCEPT EXISTS EXPLAIN FALSE \
    FLOAT FOR FROM FULL FUNCTION GRANT GROUP HAVING IF IN INDEX INNER INSERT INT INTERSECT INTERVAL INTO IS JOIN KEY \
    KEYS KILL LARGEINT LEFT LIKE LIMIT LOAD MAXVALUE MINUS NOT NULL ON OR ORDER OUTER OVER PARTITION PRECEDING \
    PRIMARY RANGE REGEXP RENAME REPLACE REVOKE RIGHT RLIKE ROLLUP ROW ROWS SELECT SEMI SET SHOW SMALLINT TABLE THEN \
    TINYINT TO TRUE UNION UNIQUE UPDATE USE USING VALUES VARCHAR WHEN WHERE WITH
    """.split(separator: " ").map(String.init))

    /// Keywords that start a statement.
    public static let statementStarters: [String] = [
        "SELECT", "WITH", "SHOW", "DESC", "EXPLAIN", "USE", "INSERT INTO", "INSERT OVERWRITE", "UPDATE", "DELETE FROM",
        "CREATE TABLE", "CREATE MATERIALIZED VIEW", "CREATE VIEW", "CREATE DATABASE", "ALTER TABLE", "ALTER MATERIALIZED VIEW",
        "DROP TABLE", "DROP MATERIALIZED VIEW", "TRUNCATE TABLE", "REFRESH MATERIALIZED VIEW", "CANCEL REFRESH MATERIALIZED VIEW",
        "ANALYZE TABLE", "SUBMIT TASK", "KILL QUERY", "SET", "SET CATALOG", "ADMIN SHOW REPLICA DISTRIBUTION FROM",
        "PAUSE ROUTINE LOAD FOR", "RESUME ROUTINE LOAD FOR", "STOP ROUTINE LOAD FOR",
    ]

    /// Useful `SHOW` targets for StarRocks.
    public static let showTargets: [String] = [
        "DATABASES", "TABLES", "FULL TABLES", "CATALOGS", "MATERIALIZED VIEWS", "PARTITIONS FROM", "TABLET FROM",
        "CREATE TABLE", "CREATE MATERIALIZED VIEW", "COLUMNS FROM", "FULL COLUMNS FROM", "DATA", "PROCESSLIST",
        "FULL PROCESSLIST", "VARIABLES LIKE", "LOAD", "ROUTINE LOAD", "ALL ROUTINE LOAD", "ALTER TABLE COLUMN",
        "ALTER TABLE ROLLUP", "ALTER MATERIALIZED VIEW", "FRONTENDS", "BACKENDS", "COMPUTE NODES", "RESOURCE GROUPS",
        "GRANTS", "ROLES", "USERS", "FUNCTIONS", "PROC", "WAREHOUSES", "STORAGE VOLUMES", "TRANSACTION",
    ]

    /// Clause keywords offered inside a query.
    public static let clauseKeywords: [String] = [
        "FROM", "WHERE", "GROUP BY", "HAVING", "ORDER BY", "LIMIT", "JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN",
        "FULL OUTER JOIN", "CROSS JOIN", "LEFT SEMI JOIN", "LEFT ANTI JOIN", "ON", "USING", "AS", "AND", "OR", "NOT",
        "IN", "IS NULL", "IS NOT NULL", "LIKE", "BETWEEN", "CASE", "WHEN", "THEN", "ELSE", "END", "DISTINCT", "UNION ALL",
        "UNION", "EXISTS", "OVER", "PARTITION BY", "ASC", "DESC", "NULLS FIRST", "NULLS LAST", "OFFSET", "INTERVAL",
        "LATERAL", "UNNEST",
    ]
}

/// A built-in function offered by completion.
public struct SQLFunction: Sendable, Hashable {
    public enum Category: String, Sendable {
        case aggregate, window, date, string, math, conditional, json, array, bitmap, tableFunction, system
    }

    public let name: String
    public let signature: String
    public let summary: String
    public let category: Category
}

public enum SQLFunctions {
    public static let all: [SQLFunction] = {
        func f(_ name: String, _ signature: String, _ summary: String, _ category: SQLFunction.Category) -> SQLFunction {
            SQLFunction(name: name, signature: signature, summary: summary, category: category)
        }
        return [
            // Aggregate
            f("count", "count(expr)", "Number of non-NULL values", .aggregate),
            f("sum", "sum(expr)", "Sum of values", .aggregate),
            f("avg", "avg(expr)", "Average of values", .aggregate),
            f("min", "min(expr)", "Minimum value", .aggregate),
            f("max", "max(expr)", "Maximum value", .aggregate),
            f("any_value", "any_value(expr)", "An arbitrary value from the group", .aggregate),
            f("approx_count_distinct", "approx_count_distinct(expr)", "Approximate distinct count (HLL)", .aggregate),
            f("ndv", "ndv(expr)", "Approximate distinct count", .aggregate),
            f("count_if", "count_if(condition)", "Rows where the condition is true", .aggregate),
            f("group_concat", "group_concat(expr [ORDER BY …] [SEPARATOR sep])", "Concatenate values of a group", .aggregate),
            f("array_agg", "array_agg(expr [ORDER BY …])", "Collect values into an array", .aggregate),
            f("percentile_approx", "percentile_approx(expr, p)", "Approximate percentile (0–1)", .aggregate),
            f("percentile_cont", "percentile_cont(expr, p)", "Exact continuous percentile", .aggregate),
            f("max_by", "max_by(value, order)", "Value at the maximum of order", .aggregate),
            f("min_by", "min_by(value, order)", "Value at the minimum of order", .aggregate),
            f("stddev", "stddev(expr)", "Population standard deviation", .aggregate),
            f("variance", "variance(expr)", "Population variance", .aggregate),
            f("bitmap_union_count", "bitmap_union_count(bitmap)", "Distinct count of a bitmap column", .bitmap),
            f("bitmap_union", "bitmap_union(bitmap)", "Union of bitmaps", .bitmap),
            f("bitmap_count", "bitmap_count(bitmap)", "Cardinality of a bitmap", .bitmap),
            f("to_bitmap", "to_bitmap(int)", "Bitmap with one value", .bitmap),
            f("bitmap_contains", "bitmap_contains(bitmap, value)", "Whether the bitmap contains value", .bitmap),
            f("hll_union_agg", "hll_union_agg(hll)", "Distinct count of an HLL column", .aggregate),
            f("hll_hash", "hll_hash(expr)", "HLL with one value", .aggregate),
            // Window
            f("row_number", "row_number() OVER (…)", "Sequential row number", .window),
            f("rank", "rank() OVER (…)", "Rank with gaps", .window),
            f("dense_rank", "dense_rank() OVER (…)", "Rank without gaps", .window),
            f("ntile", "ntile(n) OVER (…)", "Bucket number", .window),
            f("lag", "lag(expr [, offset, default]) OVER (…)", "Value from a previous row", .window),
            f("lead", "lead(expr [, offset, default]) OVER (…)", "Value from a following row", .window),
            f("first_value", "first_value(expr) OVER (…)", "First value in the window", .window),
            f("last_value", "last_value(expr) OVER (…)", "Last value in the window", .window),
            f("cume_dist", "cume_dist() OVER (…)", "Cumulative distribution", .window),
            f("percent_rank", "percent_rank() OVER (…)", "Relative rank", .window),
            // Date and time
            f("now", "now()", "Current date and time", .date),
            f("current_date", "current_date()", "Current date", .date),
            f("current_timestamp", "current_timestamp()", "Current date and time", .date),
            f("date_trunc", "date_trunc('day', datetime)", "Truncate to year/quarter/month/week/day/hour/minute", .date),
            f("time_slice", "time_slice(datetime, INTERVAL n unit)", "Start of the fixed-size time bucket", .date),
            f("date_format", "date_format(datetime, '%Y-%m-%d')", "Format a date", .date),
            f("str_to_date", "str_to_date(str, format)", "Parse a date", .date),
            f("to_date", "to_date(datetime)", "Date part", .date),
            f("date_add", "date_add(date, INTERVAL n unit)", "Add an interval", .date),
            f("date_sub", "date_sub(date, INTERVAL n unit)", "Subtract an interval", .date),
            f("datediff", "datediff(end, start)", "Days between two dates", .date),
            f("timestampdiff", "timestampdiff(unit, start, end)", "Difference in a unit", .date),
            f("days_add", "days_add(date, n)", "Add days", .date),
            f("days_sub", "days_sub(date, n)", "Subtract days", .date),
            f("year", "year(date)", "Year", .date),
            f("month", "month(date)", "Month 1–12", .date),
            f("day", "day(date)", "Day of month", .date),
            f("hour", "hour(datetime)", "Hour", .date),
            f("minute", "minute(datetime)", "Minute", .date),
            f("week", "week(date)", "Week of year", .date),
            f("dayofweek", "dayofweek(date)", "Day of week (1 = Sunday)", .date),
            f("last_day", "last_day(date)", "Last day of the month", .date),
            f("from_unixtime", "from_unixtime(seconds [, format])", "Unix time to datetime", .date),
            f("unix_timestamp", "unix_timestamp([datetime])", "Datetime to Unix time", .date),
            // String
            f("concat", "concat(a, b, …)", "Concatenate strings", .string),
            f("concat_ws", "concat_ws(sep, a, b, …)", "Concatenate with a separator", .string),
            f("substring", "substring(str, pos [, len])", "Substring (1-based)", .string),
            f("length", "length(str)", "Length in bytes", .string),
            f("char_length", "char_length(str)", "Length in characters", .string),
            f("lower", "lower(str)", "Lower case", .string),
            f("upper", "upper(str)", "Upper case", .string),
            f("trim", "trim(str)", "Remove surrounding spaces", .string),
            f("replace", "replace(str, from, to)", "Replace occurrences", .string),
            f("split", "split(str, sep)", "Split into an array", .string),
            f("split_part", "split_part(str, sep, n)", "N-th part of a split", .string),
            f("regexp_extract", "regexp_extract(str, pattern, group)", "Extract a regex group", .string),
            f("regexp_replace", "regexp_replace(str, pattern, replacement)", "Replace by regex", .string),
            f("lpad", "lpad(str, len, pad)", "Left-pad", .string),
            f("rpad", "rpad(str, len, pad)", "Right-pad", .string),
            f("instr", "instr(str, substr)", "Position of a substring", .string),
            f("starts_with", "starts_with(str, prefix)", "Whether str starts with prefix", .string),
            f("md5", "md5(str)", "MD5 hex digest", .string),
            f("parse_url", "parse_url(url, 'HOST')", "Part of a URL", .string),
            f("url_extract_parameter", "url_extract_parameter(url, name)", "Query parameter of a URL", .string),
            // JSON
            f("parse_json", "parse_json(str)", "Parse a JSON string", .json),
            f("json_query", "json_query(json, '$.path')", "JSON value at a path", .json),
            f("get_json_string", "get_json_string(json, '$.path')", "String at a JSON path", .json),
            f("get_json_int", "get_json_int(json, '$.path')", "Integer at a JSON path", .json),
            f("json_object", "json_object(key, value, …)", "Build a JSON object", .json),
            f("json_array", "json_array(value, …)", "Build a JSON array", .json),
            f("json_length", "json_length(json)", "Length of a JSON array/object", .json),
            // Math
            f("abs", "abs(x)", "Absolute value", .math),
            f("round", "round(x [, d])", "Round", .math),
            f("floor", "floor(x)", "Round down", .math),
            f("ceil", "ceil(x)", "Round up", .math),
            f("truncate", "truncate(x, d)", "Truncate decimals", .math),
            f("pow", "pow(x, y)", "Power", .math),
            f("sqrt", "sqrt(x)", "Square root", .math),
            f("ln", "ln(x)", "Natural logarithm", .math),
            f("log10", "log10(x)", "Base-10 logarithm", .math),
            f("mod", "mod(x, y)", "Remainder", .math),
            f("greatest", "greatest(a, b, …)", "Largest argument", .math),
            f("least", "least(a, b, …)", "Smallest argument", .math),
            f("rand", "rand()", "Random number in [0, 1)", .math),
            // Conditional
            f("if", "if(condition, then, else)", "Conditional value", .conditional),
            f("ifnull", "ifnull(expr, fallback)", "Fallback for NULL", .conditional),
            f("nullif", "nullif(a, b)", "NULL when a = b", .conditional),
            f("coalesce", "coalesce(a, b, …)", "First non-NULL argument", .conditional),
            // Arrays
            f("array_length", "array_length(arr)", "Number of elements", .array),
            f("array_contains", "array_contains(arr, value)", "Whether arr contains value", .array),
            f("array_join", "array_join(arr, sep)", "Join elements into a string", .array),
            f("array_distinct", "array_distinct(arr)", "Distinct elements", .array),
            f("array_sort", "array_sort(arr)", "Sorted elements", .array),
            f("element_at", "element_at(arr, index)", "Element at a 1-based index", .array),
            // Table functions and system
            f("generate_series", "generate_series(start, end [, step])", "Table of numbers (use with TABLE(…))", .tableFunction),
            f("unnest", "unnest(arr)", "Rows from an array", .tableFunction),
            f("files", "files('path' = …, 'format' = …)", "Read files from object storage", .tableFunction),
            f("current_version", "current_version()", "StarRocks version", .system),
            f("current_user", "current_user()", "Authenticated user", .system),
            f("database", "database()", "Current database", .system),
            f("catalog", "catalog()", "Current catalog", .system),
            f("uuid", "uuid()", "Random UUID", .system),
            f("sleep", "sleep(seconds)", "Pause (testing)", .system),
        ]
    }()

    public static let names: Set<String> = Set(all.map { $0.name.uppercased() })
}
