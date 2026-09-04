-- partner_code는 oacx에 등록할 partner_code
-- ID 자동 생성 DB의 경우 아래 이용
INSERT INTO VF_ORGANIZATION(PARTNER_CODE, APP_TITLE, APP_CONTENT) VALUES('__PARTNER_CODE__', '우리투자증권', '1.0.0.9');
-- Oracle, Tibero, Cubrid 등 시퀀스(시리얼) 이용 DB의 경우 ID를 시퀀스(시리얼)에서 할당 받음.
-- INSERT INTO VF_ORGANIZATION(ID, PARTNER_CODE, APP_TITLE, APP_CONTENT) VALUES(vf_organization_ai_id.NEXTVAL, '', null, null);