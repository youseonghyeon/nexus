// AppleSMC 온도 센서·팬 읽기 (~/.tools/stats-helpers/smctemp.c 를 앱 안으로 옮긴 것 + 팬 RPM).
// root·TCC 없이 IOKit AppleSMC 사용자 클라이언트로 읽는다. 함수마다 연결을 열고 닫아 상태를 두지 않는다 (어느 스레드에서 불러도 된다).
#ifndef CSMC_H
#define CSMC_H

/// 'T' 로 시작하고 온도 꼴(flt · sp78 · ioft)이며 값이 0 초과 150 이하인 키를 최대 max 개 채운다.
/// keys 는 키마다 5바이트(4글자 + NUL). 돌려주는 값은 채운 개수, AppleSMC 를 못 열면 -1.
int csmc_list_temperatures(char *keys, double *values, int max);

/// 주어진 키들(4글자씩 이어 붙인 문자열, count 개)을 읽어 values 에 채운다. 못 읽은 키는 NaN.
/// 돌려주는 값은 읽은 개수, AppleSMC 를 못 열면 -1.
int csmc_read_temperatures(const char *keys, int count, double *values);

/// 팬: FNum(팬 개수) 만큼 F<n>Ac(지금 RPM)·F<n>Mx(최대 RPM)를 actual·maximum 에 채운다 (최대 max 개).
/// 돌려주는 값은 팬 개수 (팬 없는 Mac 은 0), AppleSMC 를 못 열면 -1. 못 읽은 값은 NaN.
int csmc_read_fans(double *actual, double *maximum, int max);

#endif
