#include <stdlib.h>
#include <stdint.h>
#include "org_bitcoin_Secp256k1Context.h"
#include "include/secp256k1.h"

#define JNI_API SECP256K1_API

JNI_API jlong JNICALL Java_org_bitcoin_Secp256k1Context_secp256k1_1init_1context
  (JNIEnv* env, jclass classObject)
{
  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY | SECP256K1_CONTEXT_SIGN);
  return (uintptr_t)ctx;
}
