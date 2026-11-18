// Generated, then reviewed; keep sorted. Produced on 2026-11-18 from `SHOW BUILTIN FUNCTIONS` on StarRocks 3.3.22
// (418 names) and 4.1.7 (820 names; every 3.3 name is also listed by 4.1): the union, minus the functions the
// read-only guard denies (ai_query, get_query_profile, host_name, list_rowsets).
// `unlisted` holds syntax-level and FE-evaluated functions that the listing omits; each one was probed read-only on both
// versions as an account holding only SELECT on one table, and returns only its arguments' values or the caller's own
// session (user, roles, database, catalog, connection). The FE meta functions the listing omits are denied, not
// reviewed (`unlistedMetaFunctions`).
// To support a new StarRocks version, review every name its SHOW BUILTIN FUNCTIONS adds: the integration test
// "Reviewed functions" fails while a listed name is neither reviewed here nor denied by ReadOnlySQLGuard.

/// The built-in functions AI read-only queries may call (deny by default): none reads files, other users' data, server
/// internals or the network. User-defined functions are never on it.
enum ReviewedFunctions {
    /// Lower-case names AI read-only queries may call.
    static let names: Set<String> = listed.union(unlisted)

    /// Listed by SHOW BUILTIN FUNCTIONS on 3.3 or 4.1, minus the denied ones (816 names).
    static let listed: Set<String> = words("""
        __iceberg_transform_bucket __iceberg_transform_day __iceberg_transform_hour __iceberg_transform_month
        __iceberg_transform_timestamptz_bucket __iceberg_transform_timestamptz_day __iceberg_transform_timestamptz_hour
        __iceberg_transform_timestamptz_month __iceberg_transform_timestamptz_year __iceberg_transform_truncate
        __iceberg_transform_year abs acos add add_months adddate aes_decrypt aes_encrypt all_match any_match any_value
        any_value_combine any_value_if any_value_merge any_value_state any_value_state_merge any_value_state_union
        any_value_union append_trailing_char_if_absent approx_cosine_similarity approx_count_distinct
        approx_count_distinct_combine approx_count_distinct_if approx_count_distinct_merge approx_count_distinct_state
        approx_count_distinct_state_merge approx_count_distinct_state_union approx_count_distinct_union approx_l2_distance
        approx_top_k array_agg array_agg_combine array_agg_distinct array_agg_distinct_combine array_agg_distinct_if
        array_agg_distinct_merge array_agg_distinct_state array_agg_distinct_state_merge array_agg_distinct_state_union
        array_agg_distinct_union array_agg_if array_agg_merge array_agg_state array_agg_state_merge array_agg_state_union
        array_agg_union array_append array_avg array_concat array_contains array_contains_all array_contains_seq
        array_cum_sum array_difference array_distinct array_filter array_flatten array_generate array_intersect array_join
        array_length array_map array_max array_min array_position array_remove array_repeat array_slice array_sort
        array_sort_lambda array_sortby array_sum array_to_bitmap array_top_n array_unique_agg array_unique_agg_combine
        array_unique_agg_if array_unique_agg_merge array_unique_agg_state array_unique_agg_state_merge
        array_unique_agg_state_union array_unique_agg_union arrays_overlap arrays_zip ascii asin assert_true atan atan2 avg
        avg_combine avg_if avg_merge avg_state avg_state_merge avg_state_union avg_union bar base64_decode_binary
        base64_decode_string base64_to_bitmap bin bit_shift_left bit_shift_right bit_shift_right_logical bitand bitmap_agg
        bitmap_agg_combine bitmap_agg_if bitmap_agg_merge bitmap_agg_state bitmap_agg_state_merge bitmap_agg_state_union
        bitmap_agg_union bitmap_and bitmap_andnot bitmap_contains bitmap_count bitmap_empty bitmap_from_binary
        bitmap_from_string bitmap_has_any bitmap_hash bitmap_hash64 bitmap_intersect bitmap_max bitmap_min bitmap_or
        bitmap_remove bitmap_subset_in_range bitmap_subset_limit bitmap_to_array bitmap_to_base64 bitmap_to_binary
        bitmap_to_string bitmap_union bitmap_union_combine bitmap_union_count bitmap_union_if bitmap_union_int
        bitmap_union_int_combine bitmap_union_int_if bitmap_union_int_merge bitmap_union_int_state
        bitmap_union_int_state_merge bitmap_union_int_state_union bitmap_union_int_union bitmap_union_merge
        bitmap_union_state bitmap_union_state_merge bitmap_union_state_union bitmap_union_union bitmap_xor bitnot bitor
        bitshiftleft bitshiftright bitshiftrightlogical bitxor bool_or bool_or_combine bool_or_if bool_or_merge
        bool_or_state bool_or_state_merge bool_or_state_union bool_or_union cardinality cbrt ceil ceiling char char_length
        character_length coalesce column_compressed_size column_compressed_size_combine column_compressed_size_if
        column_compressed_size_merge column_compressed_size_state column_compressed_size_state_merge
        column_compressed_size_state_union column_compressed_size_union column_size column_size_combine column_size_if
        column_size_merge column_size_state column_size_state_merge column_size_state_union column_size_union concat
        concat_ws conv convert_tz corr corr_combine corr_if corr_merge corr_state corr_state_merge corr_state_union
        corr_union cos cosh cosine_similarity cosine_similarity_norm cot count count_combine count_if count_merge
        count_state count_state_merge count_state_union count_union covar_pop covar_pop_combine covar_pop_if covar_pop_merge
        covar_pop_state covar_pop_state_merge covar_pop_state_union covar_pop_union covar_samp covar_samp_combine
        covar_samp_if covar_samp_merge covar_samp_state covar_samp_state_merge covar_samp_state_union covar_samp_union crc32
        crc32_hash cume_dist curdate current_date current_time current_timestamp current_timezone current_version curtime
        date date_add date_diff date_format date_slice date_sub date_trunc datediff day dayname dayofmonth dayofweek
        dayofweek_iso dayofyear days_add days_diff days_sub dceil degrees dense_rank dexp dfloor dict_merge
        distinct_map_keys divide dlog1 dlog10 dpow dround ds_hll_accumulate ds_hll_combine ds_hll_count_distinct
        ds_hll_count_distinct_combine ds_hll_count_distinct_if ds_hll_count_distinct_merge ds_hll_count_distinct_state
        ds_hll_count_distinct_state_merge ds_hll_count_distinct_state_union ds_hll_count_distinct_union ds_hll_estimate
        ds_theta_count_distinct ds_theta_count_distinct_combine ds_theta_count_distinct_if ds_theta_count_distinct_merge
        ds_theta_count_distinct_state ds_theta_count_distinct_state_merge ds_theta_count_distinct_state_union
        ds_theta_count_distinct_union dsqrt e encode_fingerprint_sha256 encode_sort_key ends_with equiwidth_bucket esquery
        exchange_bytes exchange_speed exp field find_in_set first_value first_value_rewrite flat_json_meta floor fmod
        format_bytes fpow from_base64 from_binary from_days from_unixtime from_unixtime_ms fused_multi_distinct_count
        fused_multi_distinct_count_avg fused_multi_distinct_count_avg_combine fused_multi_distinct_count_avg_if
        fused_multi_distinct_count_avg_merge fused_multi_distinct_count_avg_state fused_multi_distinct_count_avg_state_merge
        fused_multi_distinct_count_avg_state_union fused_multi_distinct_count_avg_union fused_multi_distinct_count_combine
        fused_multi_distinct_count_if fused_multi_distinct_count_merge fused_multi_distinct_count_state
        fused_multi_distinct_count_state_merge fused_multi_distinct_count_state_union fused_multi_distinct_count_sum
        fused_multi_distinct_count_sum_avg fused_multi_distinct_count_sum_avg_combine fused_multi_distinct_count_sum_avg_if
        fused_multi_distinct_count_sum_avg_merge fused_multi_distinct_count_sum_avg_state
        fused_multi_distinct_count_sum_avg_state_merge fused_multi_distinct_count_sum_avg_state_union
        fused_multi_distinct_count_sum_avg_union fused_multi_distinct_count_sum_combine fused_multi_distinct_count_sum_if
        fused_multi_distinct_count_sum_merge fused_multi_distinct_count_sum_state fused_multi_distinct_count_sum_state_merge
        fused_multi_distinct_count_sum_state_union fused_multi_distinct_count_sum_union fused_multi_distinct_count_union
        generate_series get_json_bool get_json_double get_json_int get_json_object get_json_string get_variant_bool
        get_variant_date get_variant_datetime get_variant_double get_variant_int get_variant_string get_variant_time
        greatest group_concat grouping grouping_id hex hex_decode_binary hex_decode_string histogram histogram_hll_ndv
        hll_cardinality hll_deserialize hll_empty hll_hash hll_raw hll_raw_agg hll_serialize hll_union hll_union_agg
        hll_union_combine hll_union_if hll_union_merge hll_union_state hll_union_state_merge hll_union_state_union
        hll_union_union hour hour_from_unixtime hours_add hours_diff hours_sub if ifnull inet_aton initcap instr int_divide
        intersect_count is_role_in_session jodatime_format json_array json_contains json_each json_exists json_keys
        json_length json_object json_pretty json_query json_remove json_set json_string l2_distance lag last_day
        last_query_id last_value lcase lead least left length like ln localtime localtimestamp locate log log10 log2 lower
        lpad ltrim makedate mann_whitney_u_test mann_whitney_u_test_combine mann_whitney_u_test_if mann_whitney_u_test_merge
        mann_whitney_u_test_state mann_whitney_u_test_state_merge mann_whitney_u_test_state_union mann_whitney_u_test_union
        map_agg map_apply map_concat map_entries map_filter map_from_arrays map_keys map_size map_values max max_by
        max_by_combine max_by_if max_by_merge max_by_state max_by_state_merge max_by_state_union max_by_union max_combine
        max_if max_merge max_state max_state_merge max_state_union max_union md5 md5sum md5sum_numeric microseconds_add
        microseconds_sub milliseconds_add milliseconds_diff milliseconds_sub min min_by min_by_combine min_by_if
        min_by_merge min_by_state min_by_state_merge min_by_state_union min_by_union min_combine min_if min_merge min_state
        min_state_merge min_state_union min_union minute minutes_add minutes_diff minutes_sub mod money_format month
        monthname months_add months_diff months_sub multi_distinct_count multi_distinct_count_combine
        multi_distinct_count_if multi_distinct_count_merge multi_distinct_count_state multi_distinct_count_state_merge
        multi_distinct_count_state_union multi_distinct_count_union multi_distinct_sum multi_distinct_sum_combine
        multi_distinct_sum_if multi_distinct_sum_merge multi_distinct_sum_state multi_distinct_sum_state_merge
        multi_distinct_sum_state_union multi_distinct_sum_union multiply murmur_hash3_32 named_struct ndv ndv_combine ndv_if
        ndv_merge ndv_state ndv_state_merge ndv_state_union ndv_union negative next_day ngram_search
        ngram_search_case_insensitive now ntile null_or_empty nullif parse_json parse_url percent_rank percentile_approx
        percentile_approx_combine percentile_approx_if percentile_approx_merge percentile_approx_raw percentile_approx_state
        percentile_approx_state_merge percentile_approx_state_union percentile_approx_union percentile_approx_weighted
        percentile_approx_weighted_combine percentile_approx_weighted_if percentile_approx_weighted_merge
        percentile_approx_weighted_state percentile_approx_weighted_state_merge percentile_approx_weighted_state_union
        percentile_approx_weighted_union percentile_cont percentile_cont_combine percentile_cont_if percentile_cont_merge
        percentile_cont_state percentile_cont_state_merge percentile_cont_state_union percentile_cont_union percentile_disc
        percentile_disc_combine percentile_disc_if percentile_disc_lc percentile_disc_merge percentile_disc_state
        percentile_disc_state_merge percentile_disc_state_union percentile_disc_union percentile_empty percentile_hash
        percentile_union percentile_union_combine percentile_union_if percentile_union_merge percentile_union_state
        percentile_union_state_merge percentile_union_state_union percentile_union_union pi pmod positive pow power
        previous_day quarter quarters_add quarters_sub query_id radians raise_error rand random rank regexp regexp_count
        regexp_extract regexp_extract_all regexp_replace regexp_split repeat replace replace_old retention retention_combine
        retention_if retention_merge retention_state retention_state_merge retention_state_union retention_union reverse
        right round row row_number rpad rtrim sec_to_time second seconds_add seconds_diff seconds_sub session_number sha2
        sign sin sinh sleep sm3 space split split_part sqrt square st_astext st_aswkt st_circle st_contains
        st_distance_sphere st_geometryfromtext st_geomfromtext st_linefromtext st_linestringfromtext st_point
        st_polyfromtext st_polygon st_polygonfromtext st_x st_y starts_with std std_combine std_if std_merge std_state
        std_state_merge std_state_union std_union stddev stddev_combine stddev_if stddev_merge stddev_pop stddev_pop_combine
        stddev_pop_if stddev_pop_merge stddev_pop_state stddev_pop_state_merge stddev_pop_state_union stddev_pop_union
        stddev_samp stddev_samp_combine stddev_samp_if stddev_samp_merge stddev_samp_state stddev_samp_state_merge
        stddev_samp_state_union stddev_samp_union stddev_state stddev_state_merge stddev_state_union stddev_union str2date
        str_to_date str_to_jodatime str_to_map strcmp strleft strpos strright sub_bitmap subdate subdivide_bitmap substr
        substring substring_index subtract sum sum_combine sum_if sum_map sum_merge sum_state sum_state_merge
        sum_state_union sum_union tan tanh time_format time_slice time_to_sec timediff timestamp to_base64 to_binary
        to_bitmap to_date to_datetime to_datetime_ntz to_days to_iso8601 to_json to_tera_date to_tera_timestamp tokenize
        translate trim truncate ucase unhex unix_timestamp unnest unnest_bitmap upper url_decode url_encode url_extract_host
        url_extract_parameter utc_time utc_timestamp uuid uuid_numeric uuid_v7 uuid_v7_numeric var_pop var_pop_combine
        var_pop_if var_pop_merge var_pop_state var_pop_state_merge var_pop_state_union var_pop_union var_samp
        var_samp_combine var_samp_if var_samp_merge var_samp_state var_samp_state_merge var_samp_state_union var_samp_union
        variance variance_combine variance_if variance_merge variance_pop variance_pop_combine variance_pop_if
        variance_pop_merge variance_pop_state variance_pop_state_merge variance_pop_state_union variance_pop_union
        variance_samp variance_samp_combine variance_samp_if variance_samp_merge variance_samp_state
        variance_samp_state_merge variance_samp_state_union variance_samp_union variance_state variance_state_merge
        variance_state_union variance_union variant_query variant_typeof version week week_iso weekday weekofyear weeks_add
        weeks_diff weeks_sub window_funnel xx_hash3_128 xx_hash3_64 year years_add years_diff years_sub yearweek
        """)

    /// Not listed by SHOW BUILTIN FUNCTIONS, probed on 3.3 and 4.1 (22 names; current_group and current_warehouse
    /// exist on 4.1 only).
    static let unlisted: Set<String> = words("""
        cast catalog connection_id convert current_group current_role current_user current_warehouse database element_at
        extract isnotnull isnull map rlike schema session_id struct timestampadd timestampdiff typeof user
        """)

    /// Functions the servers run although SHOW BUILTIN FUNCTIONS omits them, found by probing 3.3 and 4.1: every one is
    /// denied (the integration test checks the guard refuses each). A meta function missing here is refused anyway: it is
    /// not reviewed.
    static let unlistedMetaFunctions: [String] = [
        "dict_mapping", "dictionary_get", "files", "get_query_dump", "get_query_dump_from_query_id", "inspect_all_pipes",
        "inspect_hive_part_info", "inspect_memory", "inspect_memory_detail", "inspect_mv_meta", "inspect_mv_plan",
        "inspect_mv_refresh_info", "inspect_mv_relationships", "inspect_related_mv", "inspect_table_partition_info",
        "inspect_task_runs", "lookup_string",
    ]

    private static func words(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }
}
