# File name: Dockerfile
FROM rayproject/ray-ml:2.9.2-py310

RUN pip install faster-whisper==0.10.0 pyannote.audio==3.1.1 transformers==4.37.2 TorchAudio==2.2.0 torchtext==0.17.0 pyannote.core==5.0.0 sentence-transformers==2.3.1 torch==2.2.0 lightning_fabric==2.2.0.post0 lightning-bolts==0.7 
WORKDIR /serve_app
# COPY . . 

USER root
# RUN chmod 777 /serve_app/audio_files

ENV TZ=Asia/Taipei
USER $RAY_UID
