import os
from qdrant_client import QdrantClient
from qdrant_client.http.models import Distance, VectorParams
from app.config.settings import settings
import logging

logger = logging.getLogger(__name__)

qdrant_client = QdrantClient(url=os.getenv("QDRANT_URL", "http://qdrant:6333"))

def init_qdrant(collection_name="vellum_rag"):
    try:
        collections = qdrant_client.get_collections().collections
        if not any(c.name == collection_name for c in collections):
            qdrant_client.create_collection(
                collection_name=collection_name,
                vectors_config=VectorParams(size=384, distance=Distance.COSINE),
            )
            logger.info(f"Qdrant collection {collection_name} created.")
    except Exception as e:
        logger.error(f"Failed to initialize Qdrant collection: {e}")

init_qdrant()
