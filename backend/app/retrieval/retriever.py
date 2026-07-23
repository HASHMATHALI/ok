import logging
from typing import List, Dict, Tuple
import numpy as np
from sqlalchemy.ext.asyncio import AsyncSession
from app.embeddings.embedder import embedder
from app.models.document import DocumentChunk
from app.database.qdrant import qdrant_client
from qdrant_client.http.models import Filter, FieldCondition, MatchValue, MatchAny

logger = logging.getLogger(__name__)

class Retriever:
    """Advanced Retrieval Engine using Qdrant."""

    @classmethod
    async def semantic_search(
        cls, 
        db: AsyncSession, 
        query: str, 
        k: int = 5, 
        document_ids: List[int] = None
    ) -> List[Tuple[DocumentChunk, float]]:
        """Standard Semantic search using Qdrant."""
        if document_ids is not None and not document_ids:
            return []
            
        query_vector = embedder.get_embedding(query)
        query_list = query_vector.tolist() if hasattr(query_vector, "tolist") else list(query_vector)

        qdrant_filter = None
        if document_ids is not None:
            qdrant_filter = Filter(
                must=[
                    FieldCondition(
                        key="document_id",
                        match=MatchAny(any=document_ids)
                    )
                ]
            )
            
        search_result = qdrant_client.search(
            collection_name="vellum_rag",
            query_vector=query_list,
            query_filter=qdrant_filter,
            limit=k
        )
        
        results = []
        for scored_point in search_result:
            chunk = DocumentChunk(
                id=scored_point.id,
                document_id=scored_point.payload["document_id"],
                chunk_index=scored_point.payload["chunk_index"],
                text_content=scored_point.payload["text_content"],
                page_number=scored_point.payload["page_number"]
            )
            results.append((chunk, float(scored_point.score)))
            
        return results

    @classmethod
    async def mmr_search(
        cls, 
        db: AsyncSession, 
        query: str, 
        k: int = 5, 
        document_ids: List[int] = None, 
        lambda_val: float = 0.5
    ) -> List[Tuple[DocumentChunk, float]]:
        """Maximal Marginal Relevance search using Qdrant."""
        if document_ids is not None and not document_ids:
            return []

        # Simplified for now, fallback to semantic search as Qdrant has native MMR, 
        # but requires specific config or we just return semantic for this iteration.
        # In a real app we would compute MMR locally from the Qdrant vectors 
        # (which requires retrieving vectors along with payload).
        return await cls.semantic_search(db, query, k, document_ids)

    @classmethod
    async def hybrid_search(
        cls, 
        db: AsyncSession, 
        query: str, 
        k: int = 5, 
        document_ids: List[int] = None, 
        semantic_weight: float = 0.7
    ) -> List[Tuple[DocumentChunk, float]]:
        """Fallback hybrid search using Qdrant."""
        # For this setup, we just return semantic search. 
        # Qdrant supports hybrid search natively if sparse vectors are configured.
        return await cls.semantic_search(db, query, k, document_ids)
