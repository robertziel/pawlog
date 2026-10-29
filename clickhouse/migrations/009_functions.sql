-- Server-wide SQL functions shared by the dashboard queries (one definition of source and channel).
-- Session source: utm_source, else referrer domain, else (direct).
CREATE OR REPLACE FUNCTION pawlog_source AS (utm_source, ref_domain) ->
    multiIf(utm_source != '', utm_source, ref_domain != '', ref_domain, '(direct)');

-- Default channel group, after GA4's rules (simplified: no app or video channels).
CREATE OR REPLACE FUNCTION pawlog_channel AS (ref_domain, utm_source, utm_medium) ->
    multiIf(
        utm_source = '' AND utm_medium = '' AND ref_domain = '', 'Direct',
        match(lower(utm_medium), '^(.*cp.*|ppc|retargeting|paid.*)$'),
            multiIf(match(lower(pawlog_source(utm_source, ref_domain)), '(^|\\.)(google|bing|yahoo|duckduckgo|yandex|baidu|ecosia|startpage|qwant|naver|seznam|search\\.brave)(\\.|$)'), 'Paid Search',
                    match(lower(pawlog_source(utm_source, ref_domain)), '(^|\\.)(facebook|fb|instagram|twitter|x|t|linkedin|lnkd|reddit|pinterest|tiktok|youtube|threads|bsky|mastodon)(\\.|$)'), 'Paid Social',
                    'Paid Other'),
        lower(utm_medium) IN ('display', 'banner', 'expandable', 'interstitial', 'cpm'), 'Display',
        lower(utm_medium) = 'organic' OR match(lower(pawlog_source(utm_source, ref_domain)), '(^|\\.)(google|bing|yahoo|duckduckgo|yandex|baidu|ecosia|startpage|qwant|naver|seznam|search\\.brave)(\\.|$)'), 'Organic Search',
        lower(utm_medium) IN ('social', 'social-network', 'social-media', 'sm', 'social network', 'social media')
            OR match(lower(pawlog_source(utm_source, ref_domain)), '(^|\\.)(facebook|fb|instagram|twitter|x|t|linkedin|lnkd|reddit|pinterest|tiktok|youtube|threads|bsky|mastodon|news\\.ycombinator)(\\.|$)'), 'Organic Social',
        lower(utm_medium) IN ('email', 'e-mail', 'e_mail', 'e mail') OR lower(utm_source) IN ('email', 'e-mail', 'newsletter'), 'Email',
        lower(utm_medium) = 'affiliate', 'Affiliates',
        lower(utm_medium) IN ('referral', 'app', 'link') OR ref_domain != '', 'Referral',
        'Unassigned');

-- Engaged session (GA4): 2+ pageviews or 10+ s between first and last event.
CREATE OR REPLACE FUNCTION pawlog_engaged AS (pageviews, duration_s) -> pageviews >= 2 OR duration_s >= 10;
