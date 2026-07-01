#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "org_bitcoin_NativeSecp256k1.h"
#include "include/secp256k1.h"
#include "include/secp256k1_recovery.h"

#define JNI_API SECP256K1_API

JNI_API jint JNICALL Java_org_bitcoin_NativeSecp256k1_secp256k1_1ecdsa_1verify
  (JNIEnv* env, jclass classObject, jobject byteBuff, jlong context, jint pubLen)
{
  secp256k1_context *ctx = (secp256k1_context*)(uintptr_t)context;
  unsigned char* data = (unsigned char*) (*env)->GetDirectBufferAddress(env, byteBuff);
  unsigned char* sigdata = data + 32;
  unsigned char* pubdata = sigdata + 64;

  secp256k1_ecdsa_signature sig;
  secp256k1_pubkey pubkey;

  if (!secp256k1_ecdsa_signature_parse_compact(ctx, &sig, sigdata)) return 0;
  if (!secp256k1_ec_pubkey_parse(ctx, &pubkey, pubdata, pubLen)) return 0;

  return secp256k1_ecdsa_verify(ctx, &sig, data, &pubkey);
}

JNI_API jobjectArray JNICALL Java_org_bitcoin_NativeSecp256k1_secp256k1_1ecdsa_1sign
  (JNIEnv* env, jclass classObject, jobject byteBuff, jlong context)
{
  secp256k1_context *ctx = (secp256k1_context*)(uintptr_t)context;
  unsigned char* data = (unsigned char*) (*env)->GetDirectBufferAddress(env, byteBuff);
  unsigned char* privdata = data + 32;

  secp256k1_ecdsa_signature sig;
  int ret = secp256k1_ecdsa_sign(ctx, &sig, data, privdata, NULL, NULL);

  unsigned char output64[64];
  if (ret) {
    secp256k1_ecdsa_signature_serialize_compact(ctx, output64, &sig);
  }

  jobjectArray retArray = (*env)->NewObjectArray(env, 2, (*env)->FindClass(env, "[B"), NULL);
  jbyteArray sigArray = (*env)->NewByteArray(env, 64);
  (*env)->SetByteArrayRegion(env, sigArray, 0, 64, (jbyte*)output64);
  (*env)->SetObjectArrayElement(env, retArray, 0, sigArray);

  unsigned char retVal[1];
  retVal[0] = ret;
  jbyteArray retValArray = (*env)->NewByteArray(env, 1);
  (*env)->SetByteArrayRegion(env, retValArray, 0, 1, (jbyte*)retVal);
  (*env)->SetObjectArrayElement(env, retArray, 1, retValArray);

  return retArray;
}

JNI_API jbyteArray JNICALL Java_org_bitcoin_NativeSecp256k1_secp256k1_1ecdsa_1recover
  (JNIEnv* env, jclass classObject, jobject byteBuff, jlong context, jint recId, jint compressed)
{
  secp256k1_context *ctx = (secp256k1_context*)(uintptr_t)context;
  unsigned char* data = (unsigned char*) (*env)->GetDirectBufferAddress(env, byteBuff);
  unsigned char* sigdata = data + 32;

  secp256k1_ecdsa_recoverable_signature sig;
  secp256k1_pubkey pubkey;

  if (!secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, &sig, sigdata, recId)) return NULL;
  if (!secp256k1_ecdsa_recover(ctx, &pubkey, &sig, data)) return NULL;

  unsigned char output[65];
  size_t outputLen = (compressed) ? 33 : 65;
  secp256k1_ec_pubkey_serialize(ctx, output, &outputLen, &pubkey, (compressed) ? SECP256K1_EC_COMPRESSED : SECP256K1_EC_UNCOMPRESSED);

  jbyteArray retArray = (*env)->NewByteArray(env, outputLen);
  (*env)->SetByteArrayRegion(env, retArray, 0, outputLen, (jbyte*)output);

  return retArray;
}
