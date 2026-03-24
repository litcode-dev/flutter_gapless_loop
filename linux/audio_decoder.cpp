#include "audio_decoder.h"
bool AudioDecoder::Decode(const std::string&, DecodedAudio&) { return false; }
bool AudioDecoder::DecodeUrl(const std::string&, DecodedAudio&) { return false; }
void AudioDecoder::ApplyMicroFade(std::vector<float>&, uint32_t, uint32_t) {}
