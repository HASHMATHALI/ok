import os
from fastapi import APIRouter, Depends, status, HTTPException
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy.ext.asyncio import AsyncSession
from app.database.connection import get_db
from app.api.schemas import UserRegister, UserLogin, TokenResponse, UserInfo, UserProfileUpdate
from app.services.auth_service import AuthService
from app.auth.dependencies import get_current_user
from app.models.user import User
from starlette.requests import Request
from starlette.responses import RedirectResponse
from authlib.integrations.starlette_client import OAuth
from app.config.settings import settings

router = APIRouter(prefix="/auth", tags=["Authentication"])

oauth = OAuth()
oauth.register(
    name='google',
    client_id=os.getenv("GOOGLE_CLIENT_ID", "placeholder"),
    client_secret=os.getenv("GOOGLE_CLIENT_SECRET", "placeholder"),
    server_metadata_url='https://accounts.google.com/.well-known/openid-configuration',
    client_kwargs={'scope': 'openid email profile'}
)

oauth.register(
    name='github',
    client_id=os.getenv("GITHUB_CLIENT_ID", "placeholder"),
    client_secret=os.getenv("GITHUB_CLIENT_SECRET", "placeholder"),
    access_token_url='https://github.com/login/oauth/access_token',
    authorize_url='https://github.com/login/oauth/authorize',
    api_base_url='https://api.github.com/',
    client_kwargs={'scope': 'user:email'}
)

@router.post("/register", response_model=UserInfo, status_code=status.HTTP_201_CREATED)
async def register(payload: UserRegister, db: AsyncSession = Depends(get_db)):
    """Registers a new user in the platform."""
    user = await AuthService.register(
        db=db,
        email=payload.email,
        password=payload.password,
        full_name=payload.full_name
    )
    return UserInfo(
        id=user.id,
        email=user.email,
        full_name=user.full_name,
        role=user.role
    )

@router.post("/login", response_model=TokenResponse)
async def login(payload: UserLogin, db: AsyncSession = Depends(get_db)):
    """Standard JSON API login endpoint."""
    return await AuthService.login(db=db, email=payload.email, password=payload.password)

@router.post("/token", response_model=TokenResponse, include_in_schema=False)
async def login_oauth_form(
    form_data: OAuth2PasswordRequestForm = Depends(),
    db: AsyncSession = Depends(get_db)
):
    """Fallback OAuth2 form login for Swagger UI compatibility."""
    return await AuthService.login(db=db, email=form_data.username, password=form_data.password)

@router.get("/profile", response_model=UserInfo)
async def get_profile(current_user: User = Depends(get_current_user)):
    """Fetches details of the logged-in user session."""
    return UserInfo(
        id=current_user.id,
        email=current_user.email,
        full_name=current_user.full_name,
        role=current_user.role
    )

@router.put("/profile", response_model=UserInfo)
async def update_profile(
    payload: UserProfileUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Updates user information such as full name or password."""
    if payload.full_name is not None:
        current_user.full_name = payload.full_name
    if payload.password is not None:
        from app.auth.jwt import get_password_hash
        current_user.hashed_password = get_password_hash(payload.password)
        
    db.add(current_user)
    await db.commit()
    await db.refresh(current_user)
    
    return UserInfo(
        id=current_user.id,
        email=current_user.email,
        full_name=current_user.full_name,
        role=current_user.role
    )

@router.get("/google/login")
async def google_login(request: Request):
    redirect_uri = request.url_for('google_auth')
    return await oauth.google.authorize_redirect(request, redirect_uri)

@router.get("/google/callback")
async def google_auth(request: Request, db: AsyncSession = Depends(get_db)):
    try:
        token = await oauth.google.authorize_access_token(request)
        userinfo = token.get('userinfo')
        if userinfo:
            email = userinfo['email']
            name = userinfo.get('name', 'Google User')
            
            # Upsert user based on email (placeholder logic)
            from sqlalchemy.future import select
            result = await db.execute(select(User).where(User.email == email))
            user = result.scalars().first()
            if not user:
                from app.auth.jwt import get_password_hash
                user = User(
                    email=email,
                    hashed_password=get_password_hash(os.getenv("OAUTH_DUMMY_PASSWORD", "oauth_dummy")),
                    full_name=name,
                    role="user",
                    is_active=True
                )
                db.add(user)
                await db.commit()
                await db.refresh(user)

            from app.auth.jwt import create_access_token
            access_token = create_access_token(data={"sub": str(user.id), "role": user.role})
            return {"access_token": access_token, "token_type": "bearer"}
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Google OAuth failed: {str(e)}")

@router.get("/github/login")
async def github_login(request: Request):
    redirect_uri = request.url_for('github_auth')
    return await oauth.github.authorize_redirect(request, redirect_uri)

@router.get("/github/callback")
async def github_auth(request: Request, db: AsyncSession = Depends(get_db)):
    try:
        token = await oauth.github.authorize_access_token(request)
        resp = await oauth.github.get('user', token=token)
        userinfo = resp.json()
        
        email = userinfo.get('email')
        if not email:
            # fetch emails
            emails_resp = await oauth.github.get('user/emails', token=token)
            emails = emails_resp.json()
            primary = next((e for e in emails if e.get("primary")), emails[0])
            email = primary.get("email")

        name = userinfo.get('name') or userinfo.get('login') or 'GitHub User'

        from sqlalchemy.future import select
        result = await db.execute(select(User).where(User.email == email))
        user = result.scalars().first()
        if not user:
            from app.auth.jwt import get_password_hash
            user = User(
                email=email,
                hashed_password=get_password_hash(os.getenv("OAUTH_DUMMY_PASSWORD", "oauth_dummy")),
                full_name=name,
                role="user",
                is_active=True
            )
            db.add(user)
            await db.commit()
            await db.refresh(user)

        from app.auth.jwt import create_access_token
        access_token = create_access_token(data={"sub": str(user.id), "role": user.role})
        return {"access_token": access_token, "token_type": "bearer"}
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"GitHub OAuth failed: {str(e)}")
