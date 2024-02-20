import pathlib
from gevent.pool import Pool
from locust import User, task, between
from pydub import AudioSegment

import json
import time
import logging


from websockets.sync.client import connect


class WebSocketUser(User):
    abstract = True

    def __init__(self, environment):
        super().__init__(environment)
        self.pool = Pool(1)
        with self.environment.events.request.measure("[Connect]", "Websocket"):
            self.client = connect(self.host)

    def on_stop(self):
        super().on_stop()
        logging.info("Closing websocket connection")
        self.pool.kill()
        self.client.close()


class WhisperWebSocketUser(WebSocketUser):
    host = "ws://localhost:8765"
    # wait_time = between(0.5, 1.5)

    def on_start(self):

        def _receive():
            while True:
                try:
                    transcription_str = self.client.recv()
                except Exception as e:
                    pass
                else:
                    with self.environment.events.request.measure("[Receive]", "Response"):
                        transcription = json.loads(transcription_str)
                        logging.info(
                            f"Received transcription: {transcription['text']}, processing time: {transcription['processing_time']}")
        self.pool.spawn(_receive)

    @task
    def send_streaming_audio(self):

        audio_file = "./data/eng_speech.wav"

        with open(audio_file, 'rb') as file:
            logging.info("Loading audio file")
            file_format = pathlib.Path(audio_file).suffix[1:]
            try:
                audio = AudioSegment.from_file(file, format=file_format)
            except Exception as e:
                print("File loading error:", e)

            logging.info("Start sending audio")
            for i in range(0, len(audio), 250):
                chunk = audio[i:i + 250]
                with self.environment.events.request.measure("[Send]", "Audio trunks"):
                    # logging.info(f"Sending trunk {i}...")
                    self.client.send(chunk.raw_data)
                    time.sleep(0.25)
            silence = AudioSegment.silent(duration=10000)
            self.client.send(silence.raw_data)
            logging.info("Sent silence")

        logging.info("Finished sending audio")
