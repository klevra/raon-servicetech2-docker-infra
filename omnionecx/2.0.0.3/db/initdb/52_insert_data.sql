
-- admin / 1q2w3e4r5t!@ 초기 설정
-- tibero일 경우, DATE 포맷 지정
-- ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';
INSERT INTO OACX_ADMIN (id, Name, passwd, seed, passwd_change_date, state_code, authority_code, dept_name, phone_no, fail_cnt, create_date, create_user_id, update_date, update_user_id)
 VALUES('admin', '관리자', 'CaQTVfG+rqf2uEs45ThbENjGInDwL44GhCMvpFFaWQM=', '1192658319', NULL, 'Y', '1', '관리자', '070-8240-6935', 0, '2021-03-16 09:08:19.000', '', '2021-03-16 09:08:19.000', NULL);
	
-- 인증사 목록 insert
INSERT INTO OACX_PROVIDER (ID,PROVIDER_ID,Name,CONFIG,URL,PROVIDER_TYPE,OPER_SORT,STATUS_CODE,UNUSE_STYLE,DESCRIPTION,PROVIDER_IF2,SERVICE_TYPE,CREATE_DATE,CREATE_USER_ID,UPDATE_DATE,UPDATE_USER_ID,VERSION,CERT_COST,UPPER_ID,TREE_LEVEL,PROVIDER_IF) 
VALUES ('oacx_v1.5','oacx','민간(사설)인증서',NULL,NULL,'ent','__OPER_SORT__','y',NULL,NULL,NULL,'OACX',NULL,'admin',NULL,NULL,'v1.5',0,'root','1',NULL);

INSERT INTO OACX_PROVIDER (ID,PROVIDER_ID,Name,CONFIG,URL,PROVIDER_TYPE,OPER_SORT,STATUS_CODE,UNUSE_STYLE,DESCRIPTION,PROVIDER_IF2,SERVICE_TYPE,CREATE_DATE,CREATE_USER_ID,UPDATE_DATE,UPDATE_USER_ID,VERSION,CERT_COST,UPPER_ID,TREE_LEVEL,PROVIDER_IF) 
VALUES ('cokakao_v1.5','cokakao','카카오지갑',NULL,'https://cert-sign.kakao.com','ent','__OPER_SORT__','y',NULL,NULL,NULL,'AUTH,SIGN',NULL,'admin',NULL, 'admin','v1.5',100,'oacx_v1.5','2',''),
 ('conaver_v1.5','conaver','네이버',NULL,'https://nsign-gw.naver.com','ent','__OPER_SORT__','y',NULL,NULL,NULL,'AUTH,SIGN',NULL,'admin',NULL,'admin','v1.5',0,'oacx_v1.5','2',''),
 ('coshinhan_v1.5','coshinhan','신한인증서',NULL,'https://dev-ca.shinhan.com','ent','__OPER_SORT__','y',NULL,NULL,NULL,'AUTH,SIGN',NULL,'admin',NULL,NULL,'v1.5',0,'oacx_v1.5','2',''),
 ('cokb_v1.5','cokb','KB은행',NULL,'https://openapi.kbstar.com:8443','ent','__OPER_SORT__','y',NULL,NULL,NULL,'AUTH,SIGN',NULL,'admin',NULL,'admin','v1.5',0,'oacx_v1.5','2',''),
 ('copass_v1.5','copass','통신사패스',NULL,'https://pub-api.passauth.co.kr','ent','__OPER_SORT__','y',NULL,NULL,NULL,'AUTH,SIGN',NULL,'admin',NULL,'admin','v1.5',0,'oacx_v1.5','2',''),
 ('cowoori_v1.5','cowoori','우리인증서',NULL,NULL,'ent','__OPER_SORT__','y',NULL,NULL,NULL,'AUTH,SIGN',NULL,'admin',NULL,NULL,'v1.5',0,'oacx_v1.5','2',''),
 ('conh_v1.5','conh','농협은행',NULL,NULL,'ent','__OPER_SORT__','y',NULL,NULL,NULL,'AUTH,SIGN',NULL,'admin',NULL,NULL,'v1.5',0,'oacx_v1.5','2',''),
 ('coshinhan-identify_v1.5','coshinhan-identify','신한본인확인',NULL,NULL,'ent','__OPER_SORT__','y',NULL,NULL,NULL,'IDENT',NULL,'admin',NULL,NULL,'v1.5',0,'oacx_v1.5','2',''),
 ('cotoss_v1.5','cotoss','토스직연동',NULL,NULL,'ent','__OPER_SORT__','y',NULL,NULL,NULL,'AUTH,SIGN',NULL,'admin',NULL,NULL,'v1.5',0,'oacx_v1.5','2',''),
 ('cohana_v1.5','cohana','하나인증서',NULL,NULL,'ent','__OPER_SORT__','y',NULL,NULL,NULL,'AUTH,SIGN',NULL,'admin',NULL,NULL,'v1.5',0,'oacx_v1.5','2',''),
 ('cobanksalad_v1.5','cobanksalad','뱅크샐러드',NULL,NULL,'ent','__OPER_SORT__','y',NULL,NULL,NULL,'AUTH,SIGN',NULL,'admin',NULL,'admin','v1.5',0,'oacx_v1.5','2',''),
 ('cokica_v1.5','cokica','삼성패스',NULL,'https://ses.signgate.com','ent','__OPER_SORT__','y',NULL,NULL,NULL,'AUTH,SIGN',NULL,'admin','2024-01-16 00:18:53','admin','v1.5',0,'oacx_v1.5','2',''),
 ('keysharpbiz_v1.5','keysharpbiz','키샾비즈',NULL,NULL,'ent','__OPER_SORT__','y',NULL,NULL,NULL,'keysharpbiz',NULL,'admin',NULL,'admin','v1.5',0,'root','1',''),
 ('cotoss-identify_v1.5','cotoss-identify','토스본인확인',NULL,NULL,'ent','__OPER_SORT__','y',NULL,NULL,NULL,'IDENT',NULL,'admin',NULL,NULL,'v1.5',0,'oacx_v1.5','2',NULL);
 
INSERT INTO OACX_PROVIDER (id, provider_id, Name, config, url, provider_type, oper_sort, status_code, unuse_style, description, provider_if2, service_type, create_date, create_user_id, update_date, update_user_id, VERSION, cert_cost, upper_id, tree_level, provider_if) VALUES('coidentitydocument_v1.5', 'coidentitydocument', '모바일신분증', NULL, NULL, 'ent', '__OPER_SORT__', 'y', NULL, NULL, NULL, 'MID', NULL, NULL, NULL, 'admin', 'v1.5', 0, 'oacx_v1.5', '2', '{
  "connection": {
    "max": "5",
    "route": "10",
    "timeout": "30000"    
  },
  "header": {
  	"Authorization": "Bearer eyJjb21wYW55TmFtZSI6InJhb25TbmMiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMC4wLjQuMTIzIiwiaWF0IjoxNjQ3OTI1MzU4LCJleHAiOjQ4MDM2ODUzNTh9.cXISAXapcimSXA7WPU3hXK6ek3QQ8L7ksKXsB8KTt0A",
    "Connection": "keep-alive",
    "Content-Type": "application/json;charset=utf8"
  },
  "services": {
    "authen": {
      "urls": {
        "base":"http://vcverifier-service.default.svc.cluster.local:8084",
        "qrRequest": "/api/v2/transaction/qr",
        "pushRequest":"/api/v2/transaction/push",
        "webToAppRequest":"/api/v2/transaction/web2app",
        "appToAppRequest":"/api/v2/transaction/app2app",
        "result" : "/api/v2/transaction/verify"
      },
      "body": {
        "partnerCode": "oacx",
        "serviceCode": "raonsnc.5",
        "publicKey" : "27nBJCHBTAxTLZ7Z8y3C5p7AFwQXhe8LzGWM8RFFzSne8",
        "useConverter": true
      },
      "code" : {
      	"200" : ["200"],
        "402":["30005","30005.0"]
      }
    }
  }
}
');