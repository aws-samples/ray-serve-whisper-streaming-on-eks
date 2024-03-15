from fastapi import FastAPI, WebSocket, WebSocketDisconnect

import websockets
import uuid
import json
import asyncio
import logging

from src.audio_utils import save_audio_to_file
from src.client import Client

logger = logging.getLogger()
logger.setLevel(logging.DEBUG)
fastapi_app = FastAPI()


class TranscriptionServer:
    """
    Represents the WebSocket server for handling real-time audio transcription.

    This class manages WebSocket connections, processes incoming audio data,
    and interacts with VAD and ASR pipelines for voice activity detection and
    speech recognition.

    Attributes:
        vad_pipeline: An instance of a voice activity detection pipeline.
        asr_pipeline: An instance of an automatic speech recognition pipeline.
        host (str): Host address of the server.
        port (int): Port on which the server listens.
        sampling_rate (int): The sampling rate of audio data in Hz.
        samples_width (int): The width of each audio sample in bits.
        connected_clients (dict): A dictionary mapping client IDs to Client objects.
    """

    def __init__(self, sampling_rate=16000, samples_width=2):

        self.sampling_rate = sampling_rate
        self.samples_width = samples_width
        self.connected_clients = {}

        from src.asr.asr_factory import ASRFactory
        from src.vad.vad_factory import VADFactory

        self.vad_pipeline = VADFactory.create_vad_pipeline("pyannote")
        self.asr_pipeline = ASRFactory.create_asr_pipeline("faster_whisper")

    async def handle_audio(self, client: Client, websocket: WebSocket):
        while True:
            message = await websocket.receive()
            logger.debug("received message")

            if "bytes" in message.keys():
                logger.debug("received bytes")
                client.append_audio_data(message['bytes'])
            # TODO: need to verify this case
            elif "text" in message.keys():
                
                import json

                config = json.loads(message['text'])
                if config.get('type') == 'config':
                    client.update_config(config['data'])
                    logger.debug("received config")

                    continue
            elif message["type"] == "websocket.disconnect":
                raise WebSocketDisconnect
            else:
                import json
                keys_list = list(message.keys())
                logger.debug(
                    f"{type(message)} is not a valid message type. Type is {message['type']}; keys: {json.dumps(keys_list)}")

                logger.error(
                    f"Unexpected message type from {client.client_id}")
            
            client.process_audio(websocket, self.vad_pipeline, self.asr_pipeline)


@fastapi_app.websocket("/")
async def handle_websocket(websocket: WebSocket):
    await websocket.accept()
    client_id = str(uuid.uuid4())
    logger.info(f"Client {client_id} connected")

    tr_server = TranscriptionServer() # taking a long time to init

    client = Client(client_id, tr_server.sampling_rate, tr_server.samples_width)
    tr_server.connected_clients[client_id] = client


    try:
        await tr_server.handle_audio(client, websocket)
    except WebSocketDisconnect as e:
        logger.warn(f"Connection with {client_id} closed: {e}")
    finally:
        del tr_server.connected_clients[client_id]


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(fastapi_app, host="0.0.0.0", port=8000)
    